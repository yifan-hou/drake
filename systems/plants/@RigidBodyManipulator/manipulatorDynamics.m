function [H,C,B,dH,dC,dB] = manipulatorDynamics(obj,q,v,use_mex)
% manipulatorDynamics  Calculate coefficients of equation of motion.
% [H,C,B,dH,dC,dB] = manipulatorDynamics(obj,q,v,use_mex) calculates the
% coefficients of the joint-space equation of motion, 
% H(q)*vd+C(q,v,f_ext)=B(q,v)*tau, where q, v and vd are the joint 
% position, velocity and acceleration vectors, H is the joint-space inertia
% matrix, C is the vector of gravity, external-force and velocity-product
% terms, and tau is the joint force vector.
%
% Algorithm: recursive Newton-Euler for C, and Composite-Rigid-Body for H.  
% Note that you can also get C(q,qdot)*qdot + G(q) separately, because
% C = G when qdot=0

checkDirty(obj);
compute_gradients = nargout > 3;

if (nargin<4) use_mex = true; end

if compute_gradients
  [f_ext, B, df_ext, dB] = computeExternalForcesAndInputMatrix(obj, q, v);
else
  [f_ext, B] = computeExternalForcesAndInputMatrix(obj, q, v);
end

a_grav = [zeros(3, 1); obj.gravity];

if (use_mex && obj.mex_model_ptr~=0 && isnumeric(q) && isnumeric(v))
  f_ext = full(f_ext);  % makes the mex implementation simpler (for now)
  if compute_gradients
    df_ext = full(df_ext);
    % TODO:
    [H,C,dH,dC] = HandCmex(obj.mex_model_ptr,q,v,f_ext,df_ext);
    dH = [dH, zeros(NB*NB,NB)];
  else
    [H,C] = HandCmex(obj.mex_model_ptr,q,v,f_ext);
  end
else
  kinsol = doKinematics(obj, q, compute_gradients, false, v, true);
  if compute_gradients
    [inertias_world, dinertias_world] = inertiasInWorldFrame(obj, kinsol);
    [crbs, dcrbs] = compositeRigidBodyInertias(obj, inertias_world, dinertias_world);
    [H, dH] = computeMassMatrix(obj, kinsol, crbs, dcrbs);
    [C, dC] = computeBiasTerm(obj, kinsol, a_grav, inertias_world, f_ext, dinertias_world, df_ext);
  else
    inertias_world = inertiasInWorldFrame(obj, kinsol);
    crbs = compositeRigidBodyInertias(obj, inertias_world);
    H = computeMassMatrix(obj, kinsol, crbs);
    C = computeBiasTerm(obj, kinsol, a_grav, inertias_world, f_ext);
  end
end

end

function [H, dH] = computeMassMatrix(manipulator, kinsol, crbs, dcrbs)
compute_gradient = nargout > 1;

% world frame implementation
NB = length(manipulator.body);
nv = manipulator.getNumVelocities();
H = zeros(nv, nv) * kinsol.q(1); % minor adjustment to make TaylorVar work better.

if compute_gradient
  nq = manipulator.getNumPositions();
  dHdq = zeros(numel(H), nq) * kinsol.q(1);
end

for i = 2 : NB
  Ic = crbs{i};
  Si = kinsol.J{i};
  i_indices = manipulator.body(i).velocity_num;
  F = Ic * Si;
  Hii = Si' * F;
  H(i_indices, i_indices) = Hii;
  
  if compute_gradient
    dIc = dcrbs{i};
    dSi = kinsol.dJdq{i};
    dF = matGradMultMat(Ic, Si, dIc, dSi);
    dHii = matGradMultMat(Si', F, transposeGrad(dSi, size(Si)), dF);
    dHdq = setSubMatrixGradient(dHdq, dHii, i_indices, i_indices, size(H));
  end
  
  j = i;
  while j ~= 2
    j = manipulator.body(j).parent;
    body_j = manipulator.body(j);
    j_indices = body_j.velocity_num;
    Sj = kinsol.J{j};
    Hji = Sj' * F;
    H(j_indices, i_indices) = Hji;
    H(i_indices, j_indices) = Hji';
    
    if compute_gradient
      dSj = kinsol.dJdq{j};
      dHji = matGradMultMat(Sj', F, transposeGrad(dSj, size(Sj)), dF);
      dHdq = setSubMatrixGradient(dHdq, dHji, j_indices, i_indices, size(H));
      dHdq = setSubMatrixGradient(dHdq, transposeGrad(dHji, size(Hji)), i_indices, j_indices, size(H)); % dHdq at this point
    end
  end
end
if compute_gradient
  dHdv = zeros(numel(H), nv);
  dH = [dHdq, dHdv];
end
end

function [C, dC] = computeBiasTerm(manipulator, kinsol, gravitational_accel, inertias_world, f_ext, dinertias_world, df_ext)
compute_gradient = nargout > 1;

nBodies = length(manipulator.body);
world = 1;
twist_size = 6;

nq = manipulator.getNumPositions();
nv = manipulator.getNumVelocities();

% as if we're standing in an elevator that's accelerating upwards:
root_accel = -gravitational_accel;
JdotV = kinsol.JdotV;
net_wrenches = cell(nBodies, 1);
net_wrenches{1} = zeros(twist_size, 1);

if compute_gradient
  dJdotV = kinsol.dJdotVdq;
  dnet_wrenches = cell(nBodies, 1);
  dnet_wrenches{1} = zeros(twist_size, nq);
  
  dnet_wrenchesdv = cell(nBodies, 1);
  dnet_wrenchesdv{1} = zeros(twist_size, nv);
end

for i = 2 : nBodies
  twist = kinsol.twists{i};
  spatial_accel = root_accel + JdotV{i};
  external_wrench = f_ext(:, i);
  
  if compute_gradient
    dtwist = kinsol.dtwistsdq{i};
    dspatial_accel = dJdotV{i};
    % TODO: implement external wrench gradients
%     dexternal_wrench = dexternal_wrenches(:, i);
    dexternal_wrench = getSubMatrixGradient(df_ext,1:twist_size,i,size(f_ext),1:nq);
    
    dtwistdv = zeros(twist_size, nv);
    [J, v_indices] = geometricJacobian(manipulator, kinsol, world, i, world);
    dtwistdv(:, v_indices) = J;
    dspatial_acceldv = kinsol.dJdotVidv{i};
    dexternal_wrenchdv = getSubMatrixGradient(df_ext,1:twist_size,i,size(f_ext),nq+(1:nv));
  end
  
  if any(external_wrench)
    % transform from body to world
    T_i_to_world = kinsol.T{i};
    T_world_to_i = homogTransInv(T_i_to_world);
    AdT_world_to_i = transformAdjoint(T_world_to_i)';
    external_wrench = AdT_world_to_i * external_wrench;
    
    if compute_gradient
      dT_i_to_world = kinsol.dTdq{i};
      dT_world_to_i = dinvT(T_i_to_world, dT_i_to_world);
      % TODO: implement and dAdHTransposeTimesX instead
      dAdT_world_to_i = dAdHTimesX(T_world_to_i,eye(size(T_world_to_i, 1)),dT_world_to_i,zeros(numel(T_world_to_i),nq));
      dexternal_wrench = matGradMultMat(AdT_world_to_i, external_wrench, dAdT_world_to_i, dexternal_wrench);
      dexternal_wrenchdv = AdT_world_to_i * dexternal_wrenchdv;
    end
  end
  I = inertias_world{i};
  I_times_twist = I * twist;
  net_wrenches{i} = I * spatial_accel + crf(twist) * I_times_twist - external_wrench;
  
  if compute_gradient
    dI = dinertias_world{i};
    dI_times_twist = I * dtwist + matGradMult(dI, twist);
    dnet_wrenches{i} = ...
      I * dspatial_accel + matGradMult(dI, spatial_accel) ...
      + dcrf(twist, I_times_twist, dtwist, dI_times_twist) ...
      - dexternal_wrench;
    
    dI_times_twistdv = I * dtwistdv;
    dnet_wrenchesdv{i} = ...
      I * dspatial_acceldv ...
      + dcrf(twist, I_times_twist, dtwistdv, dI_times_twistdv) ...
      - dexternal_wrenchdv;
  end
end

C = zeros(nv, 1) * kinsol.q(1);

if compute_gradient
  dC = zeros(nv, nq + nv);
end

for i = nBodies : -1 : 2
  body = manipulator.body(i);
  joint_wrench = net_wrenches{i};
  Ji = kinsol.J{i};
  tau = Ji' * joint_wrench;
  C(body.velocity_num) = tau;
  net_wrenches{body.parent} = net_wrenches{body.parent} + joint_wrench;
  
  if compute_gradient
    djoint_wrench = dnet_wrenches{i};
    dJi = kinsol.dJdq{i};
    %dtau = matGradMultMat(Ji', joint_wrench, transposeGrad(dJi, size(Ji)), djoint_wrench);
    dtau = Ji' * djoint_wrench + matGradMult(transposeGrad(dJi, size(Ji)), joint_wrench); 
    dC = setSubMatrixGradient(dC, dtau, body.velocity_num, 1, size(C), 1:nq);
    dnet_wrenches{body.parent} = dnet_wrenches{body.parent} + djoint_wrench;
    
    djoint_wrenchdv = dnet_wrenchesdv{i};
    dtaudv = Ji' * djoint_wrenchdv;
    dC = setSubMatrixGradient(dC, dtaudv, body.velocity_num, 1, size(C), nq + (1:nv));
    dnet_wrenchesdv{body.parent} = dnet_wrenchesdv{body.parent} + djoint_wrenchdv;
  end
end

if compute_gradient
  [tau_friction, dtau_frictiondv] = computeFrictionForce(manipulator, kinsol.v);
  dC(:, nq + (1:nv)) = dC(:, nq + (1:nv)) + dtau_frictiondv;
else
  tau_friction = computeFrictionForce(manipulator, kinsol.v);
end
C = C + tau_friction;
end


function [f_ext, B, df_ext, dB] = computeExternalForcesAndInputMatrix(obj, q, v)
compute_gradients = nargout > 2;

% TODO: check body indices, probably need to get rid of -1 in i_to-1 etc.

m = obj.featherstone;
B = obj.B;
NB = obj.getNumBodies();
if compute_gradients
  dB = zeros(NB*obj.num_u,2*NB);
end

if ~isempty(obj.force)
  f_ext = zeros(6,NB);
  if compute_gradients
    df_ext = zeros(6*NB,size(q,1)+size(v,1));
  end
  for i=1:length(obj.force)
    % compute spatial force should return something that is the same length
    % as the number of bodies in the manipulator
    if (obj.force{i}.direct_feedthrough_flag)
      if compute_gradients
        [force,B_force,dforce,dB_force] = computeSpatialForce(obj.force{i},obj,q,v);
        dB = dB + dB_force;
      else
        [force,B_force] = computeSpatialForce(obj.force{i},obj,q,v);
      end
      B = B+B_force;
    else
      if compute_gradients
        [force,dforce] = computeSpatialForce(obj.force{i},obj,q,v);
        dforce = reshape(dforce,numel(force),[]);
      else
        force = computeSpatialForce(obj.force{i},obj,q,v);
      end
    end
    f_ext(:,m.f_ext_map_to) = f_ext(:,m.f_ext_map_to)+force(:,m.f_ext_map_from);
    if compute_gradients
      for j=1:size(m.f_ext_map_from,2)
        i_from = m.f_ext_map_from(j);
        i_to = m.f_ext_map_to(j);
        df_ext((i_to-1)*size(f_ext,1)+1:i_to*size(f_ext,1),1:size(q,1)+size(v,1)) = df_ext((i_to-1)*size(f_ext,1)+1:i_to*size(f_ext,1),1:size(q,1)+size(v,1)) + dforce((i_from-1)*size(force,1)+1:i_from*size(force,1),1:size(q,1)+size(v,1));
      end
    end
  end
else
  f_ext=sparse(6,NB);
  if compute_gradients
    df_ext = sparse(6*NB,size(q,1)+size(v,1));
  end
end
end