classdef PelvisMotionControlBlock < DrakeSystem
 % A simple pelvis motion control block for use with bipeds. Uses PD control to regulate the pelvis
 % to a fixed height above the feet and drives the yaw to match the average foot yaw.  
 
  properties
    nq;
    Kp;
    Kd;
    dt;
    controller_data; 
    robot;
    body_ind;
    mex_ptr;
    alpha;
    nominal_pelvis_height;
    use_mex;
  end
  
  methods
    function obj = PelvisMotionControlBlock(r,name,controller_data,options)
      typecheck(r,'Biped');
      typecheck(controller_data,'QPControllerData');
      
      input_frame = getStateFrame(r);
      output_frame = BodySpatialAcceleration(r,name);
      obj = obj@DrakeSystem(0,0,input_frame.dim,output_frame.dim,true,false);
      obj = setInputFrame(obj,input_frame);
      obj = setOutputFrame(obj,output_frame);

      obj.controller_data = controller_data;
      obj.nq = getNumPositions(r);

      if nargin<4
        options = struct();
      end
      
      if isfield(options,'Kp')
        typecheck(options.Kp,'double');
        sizecheck(options.Kp,[6 1]);
        obj.Kp = options.Kp;
      else
        obj.Kp = [0; 0; 150; 200; 200; 200];
      end        

      if isfield(options,'Kd')
        typecheck(options.Kd,'double');
        sizecheck(options.Kd,[6 1]);
        obj.Kd = options.Kd;
      else
        obj.Kd = [0; 0; 50; 70; 70; 70];
      end        
        
      if isfield(options,'dt')
        typecheck(options.dt,'double');
        sizecheck(options.dt,[1 1]);
        obj.dt = options.dt;
      else
        obj.dt = 0.001;
      end
      obj = setSampleTime(obj,[obj.dt;0]); % sets controller update rate
      

      if isfield(options,'use_mex')
        sizecheck(options.use_mex,1);
        obj.use_mex = uint32(options.use_mex);
        rangecheck(obj.use_mex,0,2);
        if (obj.use_mex && exist('pelvisMotionControlmex','file')~=3)
          error('can''t find pelvisMotionControlmex.  did you build it?');
        end
      else
        obj.use_mex = 1;
      end

      obj.alpha = 0.995;
      obj.nominal_pelvis_height = 0.76;
      obj.robot = r;

      if (obj.use_mex>0)
        obj.mex_ptr = SharedDataHandle(pelvisMotionControlmex(0,obj.robot.getMexModelPtr.ptr,obj.alpha,obj.nominal_pelvis_height,obj.Kp,obj.Kd));
      end

      obj.body_ind = findLinkInd(r,name);
    end
   
    function y=output(obj,t,~,x)
      ctrl_data = obj.controller_data;
      lfoot_link_con_ind = [ctrl_data.link_constraints.link_ndx]==obj.robot.foot_body_id.left;
      rfoot_link_con_ind = [ctrl_data.link_constraints.link_ndx]==obj.robot.foot_body_id.right;

      foot_traj_ind = find(ctrl_data.link_constraints(lfoot_link_con_ind).ts<=t,1,'last');
      tt = t-ctrl_data.link_constraints(lfoot_link_con_ind).ts(foot_traj_ind);
      
      a0 = ctrl_data.link_constraints(lfoot_link_con_ind).a0(:,foot_traj_ind);
      a1 = ctrl_data.link_constraints(lfoot_link_con_ind).a1(:,foot_traj_ind);
      a2 = ctrl_data.link_constraints(lfoot_link_con_ind).a2(:,foot_traj_ind);
      a3 = ctrl_data.link_constraints(lfoot_link_con_ind).a3(:,foot_traj_ind);
      lfoot_des = evalCubicSplineSegment(tt,a0,a1,a2,a3);

      a0 = ctrl_data.link_constraints(rfoot_link_con_ind).a0(:,foot_traj_ind);
      a1 = ctrl_data.link_constraints(rfoot_link_con_ind).a1(:,foot_traj_ind);
      a2 = ctrl_data.link_constraints(rfoot_link_con_ind).a2(:,foot_traj_ind);
      a3 = ctrl_data.link_constraints(rfoot_link_con_ind).a3(:,foot_traj_ind);
      rfoot_des = evalCubicSplineSegment(tt,a0,a1,a2,a3);
      
      if (obj.use_mex == 0 || obj.use_mex == 2)
        q = x(1:obj.nq);
        qd = x(obj.nq+1:end);
        kinsol = doKinematics(obj.robot,q,false,true,qd); 
      
        % TODO: this must be updated to use quaternions/spatial velocity
        [p,J] = forwardKin(obj.robot,kinsol,obj.body_ind,[0;0;0],1); 

        lfoot = forwardKin(obj.robot,kinsol,obj.robot.foot_body_id.left,[0;0;0],0);
        rfoot = forwardKin(obj.robot,kinsol,obj.robot.foot_body_id.right,[0;0;0],0);

        eta = ctrl_data.pelvis_height_foot_reference;
        
        foot_z = (1-eta)*lfoot(3) + eta*rfoot(3);
        
        if isempty(obj.controller_data.pelvis_z_prev)
          obj.controller_data.pelvis_z_prev = p(3);
        end
        z_des = obj.alpha*obj.controller_data.pelvis_z_prev + (1-obj.alpha)*(foot_z+obj.nominal_pelvis_height); % X cm above feet
        obj.controller_data.pelvis_z_prev = z_des;

        body_des = [nan;nan;z_des;0;0;angleAverage(lfoot_des(6),rfoot_des(6))]; 
        err = [body_des(1:3)-p(1:3);angleDiff(p(4:end),body_des(4:end))];

        body_vdot = obj.Kp.*err - obj.Kd.*(J*qd);
        if obj.use_mex == 2
          % check that matlab/mex agree
          body_vdot_mex = pelvisMotionControlmex(obj.mex_ptr.data,x,lfoot_des(6),rfoot_des(6),ctrl_data.pelvis_height_foot_reference);  
          valuecheck(body_vdot_mex,body_vdot);
        end
      else
        body_vdot = pelvisMotionControlmex(obj.mex_ptr.data,x,lfoot_des(6),rfoot_des(6),ctrl_data.pelvis_height_foot_reference);  
      end
      y = [obj.body_ind;body_vdot];
    end
  end
  
end
