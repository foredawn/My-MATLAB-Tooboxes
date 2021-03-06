function [model,pie_chart,label_given,restart,ssii,option1,option2,option3,option4]=stream_kcc_load(K,data,B_n,label_all,nb_data_to_process,nb_f,varargin);
%%%
%%%  stream clustering by k-centers, using the same framework as StrAP
%%%  just replace AP by k-centers
%%% support for load all the data once
%%%
%%% INPUT:
%%%	K:  the number of clusters
%%%	data: input data
%%%	B_n: number of data for initialization
%%%	label_all: input data label, if have
%%%	nb_data_to_process: the number of data to be processed
%%%	nb_f: the number of features
%%% OUTPUT:
%%%	model: the stream clustering output model
%%%	pie_chart: the histogram description of model 
%%%	label_given: the output classification label, if have
%%%	restart: the restart time
%%%	ssii: the number of saved results files
%%%
%%%  CopyRight 2008-2010 Xiangliang Zhang
%%%  All rights reserved.

option1 = struct('distance',1,'cm',0.5);
option2 = struct('Max_cache',0,'PH',0,'delt',0.01,'lambda',30);    %% Parameter for restart triggering
option3 = struct('X',10000,'all_R',0);    %% decay window, clustering damp factor for AP
option4 = struct('egreedy',0,'gp',0,'random_start',3);    %% adaption way of 'option2.lambda'
% % PH  --- '0' use Max_cache for restart, '1' use PH for restart
% % Max_cache=300;       %%%% maximum size of Reservoir 
% % delt=0.01;            %%%% tolerance parameter
% % lambda=10;             %%%% threshold for PH

while numel(varargin),
    switch(varargin{1}),
        case {'dis','distance'}		%%% default distance = 1 (the threshold for comparing new point with the model)
            option1.distance=varargin{2};
            varargin(1:2)=[];
        case {'cm'}                     %  'cm' is the proportion of centers from memory for k-centers initial selection of centers, K*cm number of initial centers are from the previous model (memory) when restarting
	    option1.cm=varargin{2};
	    varargin(1:2)=[];
        case {'Max_cache'}
            option2.Max_cache=varargin{2};
            varargin(1:2)=[];
        case {'PH','ph'}
            option2.PH=1;
            varargin(1)=[];
        case {'delt'}
            option2.delt=varargin{2};
            varargin(1:2)=[];
        case {'lambda'}
            option2.lambda=varargin{2};
            varargin(1:2)=[];
        case {'X'}
            option3.X=varargin{2};
            varargin(1:2)=[];
        case {'all_R'}
            option3.all_R=1;		%% in PH case, using all R for restarting ? (1, yes) (0, no, only lastest 300)
            varargin(1)=[];
        case {'egreedy'}
            option4.egreedy=1;
            varargin(1)=[];
        case {'gp'}
            option4.gp=1;
            varargin(1)=[];
        case {'random_strat'}
            option4.random_start=varargin{2};
            varargin(1:2)=[];
        otherwise,
            varargin(1)=[];
    end;
end;

if option2.Max_cache
	option2.PH=0;  %%% if 'Max_cache'  is used, 'PH' will be disabled
    disp(' ')
    disp('******************************************************************')
    disp('  ''Max_cache'' is specified as restart criterion, ''PH'' and related parameters are set to 0')
    disp('******************************************************************')
end

if option4.egreedy & option4.gp
	error('error_of_lambda:test',...
        '\n******************************************************************\n  error: you are specifying two ways of adapting option2.lambda\n   	Please use either ''egreedy'' or ''pg'' ')
end

if (option4.egreedy | option4.gp) & length(option2.lambda)==1
	error('error_of_lambda:test',...
        '\n******************************************************************\n  error: you are adapting option2.lambda.\n   Please sepcify the range of option2.lambda, e.g., ''lambda'',[20 60] ')
end

if (~option4.egreedy & ~option4.gp) & length(option2.lambda)==2
 	error('error_of_lambda:test',...
        '\n******************************************************************\n  error: you are using fixed option2.lambda\n   	Please sepcify a fixed value, instead of the range of option2.lambda, e.g., ''lambda'',20 ')
end

if option4.gp
alpha=1e-3;
belta = 5;
end

X=option3.X

label_given=zeros(nb_data_to_process,1);

INI_N2=5000;  %%% size of Reservoir (just set for efficiency, not effect the trigerring of restart)
Reservoir=zeros(INI_N2,nb_f);
if isnumeric(label_all)
	Label_res=zeros(INI_N2,1);
else
        Label_res=num2cell(zeros(INI_N2,1));
end	
D_Out=zeros(INI_N2,2);

%% initialization part
B=data(1:B_n,:);
label=label_all(1:B_n);

S=similarity_nse(B);
best_IDX = [];
best = -inf;
loop_num = 20; 
for i = 1 : loop_num % Loop 20 times, find the clusterings with minimal sum of point-to-centroid distances
    [idx,dpsim]=kcc(S,K);
    sumd=dpsim(length(dpsim));  % the last one
    if sumd > best % is this clustering has smaller minimal sum of point-to-centroid distances?
       best = sumd;
       best_IDX = idx;
    end
end
idx=best_IDX;
sumd=best;

cluster = build_cluster(idx,B,label);
label_given(1:B_n)=com_accu(label,label(idx));
N_c=length(cluster.n)

clear B S ccc idx temp N_c dpsim error_rate expref netsim

if option2.PH
    r_mean=0; m_current=0; M_current=0; PH_current=0; r_meanoo=0;
end
start_point=B_n+1;
restart=[];

model.initial=cluster;
model.initial = rmfield(model.initial, 'touch');

i=B_n;
pie_chart=[]; chart2=zeros(1,length(cluster.n)+1);
ssii=1;    %% saving index
n_res=0;

%% --- Learning initialization ---
if option4.egreedy
	actions = linspace(option2.lambda(1),option2.lambda(2),10)';
	table_action = [actions , zeros(size(actions, 1), 2)];
    current_lambda_idx=ceil(rand() * size(actions, 1));
	current_lambda = actions(current_lambda_idx);
	lambda_all=current_lambda;
end

if option4.gp
	current_lambda =  rand()*(option2.lambda(2)-option2.lambda(1)) + option2.lambda(1);
	pts_action = [current_lambda, 0];
end

if ~option4.egreedy & ~option4.gp
  current_lambda =  option2.lambda;
end

%% --- BIG LOOP ---
while 1

    i=i+1;
    %% --- STOP CONDITIONS ---
    if (i > nb_data_to_process)
        break ;
    end

    di=data(i,:);
    ki=length(cluster.n);
    tem1=repmat(di,ki,1) - cluster.ex;
    tempd=diag(tem1*tem1').^0.5;      clear tem1   %% compute the distance between "data_i" and "exemplars"

    [mind,iin]=min(tempd);

    label=label_all(i);
   
    if (mind > option1.distance)
        n_res=n_res+1;
        Reservoir(n_res,:)=di;
        D_Out(n_res,:)=[i abs(mind)];

        label_given(i)=-1;
        Label_res(n_res)=label;
        maxd_rr=1;                   %%%  for PH 
        chart2(1)=chart2(1)+1;
    else
        maxd_rr=2;                   %%%   for PH 
        chart2(iin+1)=chart2(iin+1)+1;
        ddelt=i-cluster.touch(iin);
        if ddelt >= X
            cluster.n(iin)=1;
            cluster.touch(iin)=i;
            cluster.meanstd(iin,:)=[0 0 tempd(iin) tempd(iin)^2];
        else
            temon=cluster.n(iin)/(cluster.n(iin)+1);
            cluster.n(iin)=cluster.n(iin)*(X/(X+ddelt))+ temon;         %%% update the exemplar
            cluster.touch(iin)=i;
            miu2=cluster.meanstd(iin,3)*(X/(X+ddelt))+temon*tempd(iin);    %%% the sum of distance between elem and ex_k
            sigma2=cluster.meanstd(iin,4)*(X/(X+ddelt))+temon*tempd(iin)^2;    %%% the sum of squared distance between elem and ex_k
            if cluster.n(iin)>1
                miu=miu2/(cluster.n(iin)-1);
            else
                miu=0;
            end
            if cluster.n(iin)>2
                sigma=abs((sigma2-(miu^2)*(cluster.n(iin)-1))/(cluster.n(iin)-2))^0.5;
            else
                sigma=0;
            end

            cluster.meanstd(iin,:)=[miu sigma miu2 sigma2];
        end

        cluster.label_all{iin}=update_context(cluster,'label_all',label,iin);
        label_given(i)=com_accu(label,cluster.label(iin));
    end

    if option2.PH
        %%% the Page-Hinkley(PH) statistics
        r_meanoo=(r_meanoo*(i-start_point)+maxd_rr)/(i-start_point+1);
        rr=maxd_rr/r_meanoo;
        r_mean=(r_mean*(i-start_point)+rr)/(i-start_point+1);
        m_current=m_current+ rr-r_mean+option2.delt;
        if abs(m_current) > M_current
            M_current=abs(m_current);
        end
        PH_current=M_current-m_current;
    end

    ReStart=0;
    if option2.PH
        if PH_current > current_lambda
            if n_res > 30
            	ReStart=1;
	        end
        end
    elseif (n_res>=option2.Max_cache)
        ReStart=1;
    end


    if ReStart
       disp(sprintf('restart_at %d',i));
       N_re=n_res;

       if N_re > INI_N2
           disp('error: the size of initialization of Reservior is too small')
       end

        restart=[restart;i];

        name=['b_restart' num2str(length(restart))];

        pie_chart.(name)=chart2;

        rremove=find((i-cluster.touch)>=X); nnremove=length(rremove);
        cluster.touch(rremove)=[];
        cluster.n(rremove)=[];
        cluster.ex_idx(rremove)=[];
        cluster.ex(rremove,:)=[];
        cluster.meanstd(rremove,:)=[];
        cluster.label(rremove)=[];

        cluster.label_all(rremove)=[];

        for ccci=1:length(cluster.n)
            delti=i-cluster.touch(ccci);
            cluster.n(ccci)=cluster.n(ccci)*(X/(X+delti));
            cluster.meanstd(ccci,3)=cluster.meanstd(ccci,3)*(X/(X+delti));    %%% the sum of distance between elem and ex_k
            cluster.meanstd(ccci,4)=cluster.meanstd(ccci,4)*(X/(X+delti));
        end

        if option2.PH
            r_mean=0; m_current=0; M_current=0; PH_current=0; r_meanoo=0;; %%clear the PH
        end
        start_point=i+1;
        %%% update the model
	   if option3.all_R
        	reservoir=Reservoir(1:n_res,:);
        	D_out=D_Out(1:n_res,:);
        	label_res=Label_res(1:n_res);
       else
		    if n_res<300
        		reservoir=Reservoir(1:n_res,:);
        		D_out=D_Out(1:n_res,:);
        		label_res=Label_res(1:n_res);
       		else
	       		ssn=n_res-299;
			    reservoir=Reservoir(ssn:n_res,:);
			    D_out=D_Out(ssn:n_res,:);
        		label_res=Label_res(ssn:n_res);
			    N_re=300;
            end
       end
        
        new_set=[cluster.ex;reservoir];
        f_all=[cluster.n;ones(N_re,1)];

        S_up=similarity_nse(new_set);

        % --- RESTART using k-centers with memory ---
	Ko=length(cluster.label);
       best_IDX = [];
       best = -inf;       
       for iloop = 1 : loop_num % Loop 20 times, find the clusterings with minimal sum of point-to-centroid distances
           [idx,dpsim]=kcc_memory(S_up,K,Ko,option1.cm);
           sumd=dpsim(length(dpsim));  % the last one
           if sumd > best % is this clustering has smaller minimal sum of point-to-centroid distances?
     	      best = sumd;
	      best_IDX = idx;
           end
       end
       idx=best_IDX;
 
        clear S_up S_new IDX S_or S_new u_res idx_res f_res all_res idx_all_own idx_all_res  idx_exold idx_exold_res idx_res idx_ress nc_ex

        idx_or=[cluster.ex_idx;D_out(:,1)];
        cluster = update_cluster(cluster,idx,new_set,idx_or,f_all,label_res);
        %% --- UPDATE REWARDS
	if option4.egreedy
           table_action(current_lambda_idx, 2) = table_action(current_lambda_idx, 2) + mean(cluster.meanstd(:,1));
           table_action(current_lambda_idx, 3) = table_action(current_lambda_idx, 3) + 1;
	end

	if option4.gp
           if (length(restart) == 1)
              pts_action(end, 2) = mean(-cluster.meanstd(:,1)) - alpha* 6 * log(restart(end) - B_n)  -  belta*n_res/ (restart(end) - B_n);
           else
              pts_action(end, 2) = mean(-cluster.meanstd(:,1)) - alpha* 6 * log(restart(end) - restart(end-1))  -  belta* n_res/ (restart(end) - restart(end-1));
           end
	end
	
        %%% --- CHOOSE the Lambda---
	if option4.egreedy
           if (sum(table_action(:,3)) <= option4.random_start)
               current_lambda_idx=ceil(rand() * size(actions, 1));
               current_lambda = actions(current_lambda_idx);
           else
               current_lambda_idx=egreedy_lambda(table_action ,0.05);
               current_lambda = actions(current_lambda_idx);
           end
%        table_action
           lambda_all=[lambda_all;current_lambda];
        end

	if option4.gp
           if (size(pts_action,1) <= option4.random_start)
              current_lambda = rand()*(option2.lambda(2)-option2.lambda(1)) + option2.lambda(1);
           else
              current_lambda = gp_lambda(pts_action, option2.lambda); 
           end
           pts_action  = [pts_action; current_lambda, 0];
%           pts_action([end-1 end],:)
    end

        n_res=0;
        reservoir=[]; label_res=[]; D_out=[];

        chart2=zeros(1,length(cluster.n)+1);
        name=['a_restart' num2str(length(restart))];
        model.(name)=cluster;
        model.(name) = rmfield(model.(name), 'touch');

        clear hIout hres f_all idx idx_or new_set range label_res1 re_idxx;

        if length(restart) >= 30
            save_name=['res' num2str(ssii)]
            save(save_name,'model','label_given','restart','pie_chart');

            clear model pie_chart
            restart = [];
            ssii=ssii+1;
        end
    end
end

save_name=['res' num2str(ssii)]
save(save_name,'model','label_given','restart','pie_chart');

if option4.egreedy
   save lambda_adaption_by_egreedy table_action lambda_all
end

if option4.gp
   save lambda_adaption_by_gp pts_action
end
