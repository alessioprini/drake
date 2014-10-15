function relativePositionTest(visualize)
  import drakeFunction.*
  import drakeFunction.euclidean.*
  import drakeFunction.kinematic.*

  if nargin < 1, visualize = false; end

  %% Initial Setup
  % Create the robot
  w = warning('off','Drake:RigidBodyManipulator:UnsupportedContactPoints');
  warning('off','Drake:RigidBodyManipulator:UnsupportedVelocityLimits');
  warning('off','Drake:RigidBodyManipulator:UnsupportedJointLimits');
  options.floating = true;
  urdf = fullfile(getDrakePath(),'examples','Atlas','urdf','atlas_minimal_contact.urdf');
  rbm = RigidBodyManipulator(urdf,options);
  warning(w);
  nq = rbm.getNumPositions();

  % Initialize visualization (if needed)
  if visualize
    lcmgl = LCMGLClient('relativePositionTest');
    v = rbm.constructVisualizer();
  end

  % Create short name for R^3
  R3 = drakeFunction.frames.realCoordinateSpace(3);

  % Load nominal posture
  S = load(fullfile(getDrakePath(),'examples','Atlas','data','atlas_fp.mat'));
  q_nom = S.xstar(1:nq);
  q0 = q_nom;

  %% Test a basic RelativePosition object
  % Create a DrakeFunction that computes the world position of the hand points
  hand_pts_in_body = rbm.getBody(rbm.findLinkInd('l_hand')).getTerrainContactPoints();
  hand_pts_fcn = RelativePosition(rbm,'l_hand','r_hand',hand_pts_in_body);

  % Evaluate that DrakeFunction
  kinsol0 = rbm.doKinematics(q0,false,false);
  [pos,J] = hand_pts_fcn.eval(q0,kinsol0);

  if visualize
    lcmgl.glColor3f(1,0,0);
    for pt = reshape(pos,3,[])
      lcmgl.sphere(pt,0.05,20,20);
    end
    rbm.drawLCMGLAxes(lcmgl,q0,rbm.findLinkInd('l_hand'));
    lcmgl.switchBuffers();
    v.draw(0,q0);
  end

  % Check the gradients of the DrakeFunction
  [f,df] = geval(@(q) eval(hand_pts_fcn,q,rbm.doKinematics(q)),q0,struct('grad_method',{{'user','numerical'}},'tol',1e-4));


  %% Solve an inverse kinematics problem
  
  %% Constraints on body points
  % Create a DrakeFunction that computes the signed distance from a point to
  % the xy-plane
  single_pt_dist_to_ground = SignedDistanceToHyperplane(Point(R3,0),Point(R3,[0;0;1]));

  %% Enforce that the corners of the left foot be on the same plane as the right foot
  % Create a DrakeFunction that computes the world positions of foot points
  lfoot_pts_in_body = rbm.getBody(rbm.findLinkInd('l_foot')).getTerrainContactPoints();
  lfoot_pts_fcn = RelativePosition(rbm,'l_foot','r_foot',lfoot_pts_in_body);
  rfoot_pts_in_body = rbm.getBody(rbm.findLinkInd('r_foot')).getTerrainContactPoints();

  % Create a DrakeFunction that computes the signed distances from m points to
  % the xy-plane, where m = foot_pts_fcn.n_pts
  dist_to_rfoot_plane_fcn = duplicate(single_pt_dist_to_ground,lfoot_pts_fcn.n_pts);

  % Create an constraint mandating that the signed distances between the foot
  % points and the ground be zero
  lb = mean(rfoot_pts_in_body(3,:))*ones(lfoot_pts_fcn.n_pts,1);
  ub = lb;
  foot_on_same_plane_cnstr = DrakeFunctionConstraint(lb,ub,dist_to_rfoot_plane_fcn(lfoot_pts_fcn));

  %% Enforce that the projection of the COM onto the xy-plane be within the
  %% convex hull of the foot points
  % Create a frame for the convex weights on the foot points
  weights_frame = frames.realCoordinateSpace(lfoot_pts_fcn.n_pts);

  % Create a DrakeFunction that computes the COM position
  com_fcn = WorldPosition(rbm,0);
  % Add unused inputs for the weights
  com_fcn = addInputFrame(com_fcn,weights_frame);

  % Create a DrakeFunction that computes a linear combination of points in R3
  % given the points and the weights as inputs
  lin_comb_of_pts = LinearCombination(lfoot_pts_fcn.n_pts,R3);
  % Create a DrakeFUnction that computes a linear combination of the foot
  % points given joint-angles and weights as inputs
  lin_comb_of_foot_pts = lin_comb_of_pts([lfoot_pts_fcn;Identity(weights_frame)]);

  % Create a DrakeFunction that computes the difference between the COM
  % position computed from the joint-angles and the linear combination of the
  % foot points.
  support_polygon{1} = minus(com_fcn,lin_comb_of_foot_pts,true);
  support_polygon{2} = Identity(weights_frame);

  % Create a DrakeFunction that computes the sum of the weights
  support_polygon{3} = Linear(weights_frame,frames.realCoordinateSpace(1),ones(1,lfoot_pts_fcn.n_pts));

  % Create quasi-static constraints
  % xy-coordinates of COM must match a linear combination of the foot points
  % for some set of weights 
  qsc_cnstr{1} = DrakeFunctionConstraint([0;0;-Inf],[0;0;Inf],support_polygon{1});

  % The weights must be between 0 and 1
  lb = zeros(lfoot_pts_fcn.n_pts,1);
  ub = ones(lfoot_pts_fcn.n_pts,1);
  qsc_cnstr{2} = DrakeFunctionConstraint(lb,ub,support_polygon{2});

  % The weights must sum to 1
  qsc_cnstr{3} = DrakeFunctionConstraint(1,1,support_polygon{3});

  Q = eye(numel(q_nom));
  prog = InverseKinematics(rbm,q_nom);
  prog = prog.setQ(Q);
  q_inds = prog.q_idx;
  w_inds = reshape(prog.num_vars+(1:lfoot_pts_fcn.n_pts),[],1);
  prog = prog.addDecisionVariable(numel(w_inds));
  
  prog = prog.addConstraint(foot_on_same_plane_cnstr,q_inds,prog.kinsol_dataind);
%   prog = prog.addConstraint(qsc_cnstr{1},[{q_inds};{w_inds}],{1});
  prog = prog.addConstraint(qsc_cnstr{2},w_inds);
  prog = prog.addConstraint(qsc_cnstr{3},w_inds);

  time_prog = tic;
  [q,F,info] = solve(prog,q0);
  display(snoptInfo(info))
  toc(time_prog);

  if visualize
    kinsol = doKinematics(rbm,q);
    com = getCOM(rbm,kinsol);
    lcmgl.glColor3f(1,0,0);
    lcmgl.sphere([com(1:2);0],0.02,20,20);
    lcmgl.switchBuffers();
    v.draw(0,q);
  end
end
