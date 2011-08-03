class TeamboxData

  #Used to wrap non active record errors
  class DummyObject; include ActiveRecord::Validations; end

  def unserialize_user(udata, can_create_users)
    user_name = (@imported_users[udata['username']] || udata['username']).strip
    user = User.find_by_login(user_name)
    if user.nil? and can_create_users
      user = User.new(udata)
      user.login = udata['username']
      user.password = user.password_confirmation = udata['password'] || rand().to_s
      attempt_save(user)
    end

    if user && user.errors.empty?
      @imported_users[udata['id']] = user
      @processed_objects[:user] << user.id
      import_log(user, "#{udata['username']} -> #{user_name}")
    end
  end

  def unserialize_users(dump, opts)
    @processed_objects[:user] = []

    dump['users'].each{ |u| unserialize_user u, opts[:create_users]}
  end

  def unserialize_organizations(dump, opts)
    @processed_objects[:organization] = []

    (dump['organizations']||[]).map do |organization_data|
      unserialize_organization organization_data, opts[:create_organizations]
    end
  end

  def unserialize_organization(organization_data, can_create_organizations)
    organization_name = @organization_map[organization_data['permalink']] || organization_data['permalink']
    org = Organization.find_by_permalink(organization_name)

    if user and org and !org.is_admin?(user)
      add_unprocessed_object("users", "#{user} needs to be an admin of #{org}")
      return
    end

    if org.nil?
      if can_create_organizations
        org = unpack_object(Organization.new, organization_data, [])
        org.permalink = organization_name
        attempt_save(organization)
      else
        add_unprocessed_object("organizations", "Organization could not be resolved DATA: #{organization_data.inspect}")
        return
      end
    end

    if org && org.errors.empty?
      @organization_map[organization_data['id']] = org
      @processed_objects[:organization] << org.id
      import_log(organization)

      Array(organization_data['members']).each do |member_data|
        org_user = resolve_user(member_data['user_id'])
        if org_user && !org.is_user?(org_user)
          unless org.add_member(org_user, member_data['role']) 
            add_unprocessed_object("memberships", "Unable to add member (#{member_data['user_id']}) to '#{org.permalink} (#{org.id})': #{member_data.inspect}")
          end
        end
      end
    end
  end

  def unserialize_teambox(dump, object_maps, opts={})
    ActiveRecord::Base.transaction do
      @object_map = {
        'User' => {},
        'Organization' => {}
      }.merge(object_maps)

      @processed_objects = {}
      @unprocessed_objects = {}
      @imported_users = @object_map['User'].clone
      @organization_map = @object_map['Organization'].clone

      unserialize_users dump, opts

      unserialize_organizations dump, opts

      @processed_objects[:project] = []
      @imported_people = {}
      @projects = (dump['projects']||[]).map do |project_data|
        @project = Project.find_by_permalink(project_data['permalink'])
        if @project
          project_data['permalink'] += "-#{rand}"
        end
        @project = unpack_object(Project.new, project_data, [])
        @project.is_importing = true
        @project.import_activities = []
        @project.user = resolve_user(project_data['owner_user_id'])
        @project.organization = @organization_map[project_data['organization_id']] || @project.user.organizations.first

        attempt_save(@project) do
          import_log(@project)

          Array(project_data['people']).each do |person_data|
            person = @project.add_user(resolve_user(person_data['user_id']), 
                              :role => person_data['role'],
                              :source_user => user ? user : resolve_user(person_data['source_user_id']))
            if !person || (person && !person.errors.empty?)
              add_unprocessed_object('people', "Person already exists in project: '#{@project.permalink} (#{@project.id})' OR unable to add person to project: #{person_data.inspect}")
            end
            @imported_people[person_data['id']] = person
          end

          # Note on commentable objects: callbacks may be invoked which may change their state. 
          # For now we will play dumb and re-assign all attributes after we have unpacked comments.
          Array(project_data['conversations']).each do |conversation_data|
            conversation = unpack_object(@project.conversations.build, conversation_data)
            conversation.is_importing = true

            attempt_save(conversation) do
              import_log(conversation)

              unpack_comments(conversation, conversation_data['comments'])

              conversation_object = unpack_object(conversation, conversation_data)
              attempt_save(conversation_object) do
                import_log(conversation_object)
              end
            end
          end

          Array(project_data['task_lists']).each do |task_list_data|
            task_list = unpack_object(@project.task_lists.build, task_list_data)

            attempt_save(task_list) do
              import_log(task_list)

              unpack_comments(task_list, task_list_data['comments'])

              Array(task_list_data['tasks']).each do |task_data|
                # Tasks automatically create comments, so we need to be careful!
                task = unpack_object(task_list.tasks.build, task_data)

                # To determine the initial state of the task, we need to look at the first comment
                if task_data['comments'] && task_data['comments'].length > 0
                  first_comment = task_data['comments'][0]
                  task.status = first_comment['previous_status'] if first_comment['previous_status']
                  task.assigned_id = resolve_person(first_comment['previous_assigned_id']).id if first_comment['previous_assigned_id']
                  task.due_on = first_comment['previous_due_on'] if first_comment['previous_due_on']
                end

                task.updating_date = task.created_at
                task.updating_user = task.user
                #In legacy data status can be nil, we transform it to 0
                task.status = task.status.to_i

                attempt_save(task) do
                  import_log(task)
                  unpack_task_comments(task, task_data['comments'])

                  task.updating_date = task.created_at
                  task.updating_user = task.user
                  task = unpack_object(task, task_data)
                  task.status = task.status.to_i
                  attempt_save(task)
                end
              end

              task_list_object = unpack_object(task_list, task_list_data)
              attempt_save(task_list_object)
            end
          end

          Array(project_data['pages']).each do |page_data|
            page = unpack_object(@project.pages.build, page_data)
            attempt_save(page) do
              import_log(page)

              obj_type_map = {'Note' => :notes, 'Divider' => :dividers}

              Array(page_data['slots']).each do |slot_data|
                next if obj_type_map[slot_data['rel_object_type']].nil? # not handled yet
                rel_object = unpack_object(page.send(obj_type_map[slot_data['rel_object_type']]).build, slot_data['rel_object'])
                rel_object.updated_by = page.user
                attempt_save(rel_object) do
                  rel_object.page_slot.position = slot_data['position']
                  attempt_save(rel_object.page_slot) do
                    import_log(rel_object)
                  end
                end
              end

            end
          end

          @processed_objects[:project] << @project.id
          @project
        end
      end

      self.projects = @processed_objects[:project]

      # Restore all activities
      @projects.map(&:import_activities).flatten.sort_by{|a|a[:date]}.each do |activity|
        if activity[:target_type] == Comment
          # touch activity related to that comment's thread
          Activity.last(:conditions => ["target_type = ? AND target_id = ?",
                                        activity[:comment_target_type], activity[:comment_target_id]]).try(:touch)
        end
        act = Activity.new(
          :project_id => activity[:project].id,
          :target_id => activity[:target_id],
          :target_type => activity[:target_class].to_s,
          :action => activity[:action],
          :user_id => activity[:creator_id],
          :comment_target_type => activity[:comment_target_type],
          :comment_target_id => activity[:comment_target_id])
        act.created_at = activity[:date]
        act.updated_at = activity[:date]
        attempt_save(act)
      end

      @projects.each do |project|
        project.is_importing = false
        project.log_activity(self, 'create', user.id) if user
      end
    end
  end
  
  def unpack_object(object, data, non_mass=[])
    object.tap do |obj|
      obj.attributes = data
      
      non_mass.each do |key|
        obj.send("#{key}=", data[key]) if data[key]
      end
      
      obj.project = @project if obj.respond_to? :project
      if obj.class != Project and obj.respond_to? :user_id
        if data['user_id'].nil?
          add_unprocessed_object(object.class.underscore, "#{object.class.to_s} '#{object.to_s}' does not have a valid user")
          return nil
        else
          obj.user_id = resolve_user(data['user_id']).id if data['user_id']
        end
      end
      if obj.respond_to? :assigned_id
        obj.assigned_id = resolve_person(data['assigned_id']).try(:id) if data['assigned_id']
      end
      obj.watcher_ids = data['watchers'].map{|u| @imported_users[u].try(:id)}.compact if data['watchers'] and obj.respond_to?(:watcher_ids)
      obj.created_at = data['created_at'] if data['created_at']
      obj.updated_at = data['updated_at'] if data['updated_at']
    end
  end
  
  def unpack_comments(obj, comments)
    return if comments.nil?
    comments.each do |comment_data|
      comment = unpack_object(@project.comments.build, comment_data)
      comment.is_importing = true
      comment.assigned_id = resolve_person(comment_data['assigned_id']).try(:id) if data['assigned_id']
      comment.target = obj
      attempt_save(comment) do
        import_log(comment)
      end
    end
  end
  
  def unpack_task_comments(task, comments)
    # comments on tasks work differently. We need to UPDATE the task!
    return if comments.nil?
    comments.each do |comment_data|
      comment = unpack_object(task.comments.build, comment_data)
      comment.is_importing = true
      comment.assigned_id = resolve_person(comment_data['assigned_id']).try(:id) if data['assigned_id']
      task.updating_user = comment.user
      task.updating_date = comment.created_at
      attempt_save(task) do
        import_log(comment)
      end
    end
  end

end
