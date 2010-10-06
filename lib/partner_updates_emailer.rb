# Used to generate (daily, weekly, monthly) emails to partners and users submitting content with lists of
# comments and curator actions on their objects or pages containing their objects
module PartnerUpdatesEmailer
  
  def self.send_email_updates
    agent_contacts_ready = AgentContact.find(:all, :conditions => "last_report_email IS NULL OR DATE_ADD(last_report_email, INTERVAL email_reports_frequency_hours HOUR) <= NOW()", :include => [{:agent => :content_partner}])
    users_ready = User.find(:all, :joins => :users_data_objects, :conditions => "last_report_email IS NULL OR DATE_ADD(last_report_email, INTERVAL email_reports_frequency_hours HOUR) <= NOW()", :group => 'users.id')
    
    agent_contact_frequencies = agent_contacts_ready.collect{|p| p.email_reports_frequency_hours}
    user_frequencies = users_ready.collect{|p| p.email_reports_frequency_hours}
    
    all_frequencies = agent_contact_frequencies | user_frequencies
    
    for frequency_hours in all_frequencies
      all_activity = self.all_activity_since_hour(frequency_hours)
      self.send_emails_to_partners(all_activity[:partner_activity], agent_contacts_ready, frequency_hours)
      self.send_emails_to_users(all_activity[:user_activity], users_ready, frequency_hours)
    end
  end
  
  def self.send_emails_to_partners(partner_activity, agent_contacts, frequency_hours)
    partner_activity.each do |partner_id, activity|
      agents_for_this_partner = agent_contacts.select{|ac| !ac.agent.content_partner.nil? && ac.email_reports_frequency_hours == frequency_hours && ac.agent.content_partner.id == partner_id}
      for agent in agents_for_this_partner
        Notifier.deliver_comments_and_actions_to_partner_or_user(agent, activity)
      end
    end
  end
  
  def self.send_emails_to_users(user_activity, users, frequency_hours)
    user_activity.each do |user_id, activity|
      user_to_update = users.select{|u| u.email_reports_frequency_hours == frequency_hours && u.id == user_id}
      for user in user_to_update
        Notifier.deliver_comments_and_actions_to_partner_or_user(user, activity)
      end
    end
  end
  
  
  def self.all_activity_since_hour(number_of_hours = 24)
    actions = self.all_actions_since_hour(number_of_hours)
    comments = self.all_comments_since_hour(number_of_hours)
    
    partner_activity = {}
    actions[:partner_actions].each do |id, a|
      partner_activity[id] ||= { :actions => [], :object_comments => [], :page_comments => [] }
      partner_activity[id][:actions] = a
    end
    comments[:partner_comments][:objects].each do |id, c|
      partner_activity[id] ||= { :actions => [], :object_comments => [], :page_comments => [] }
      partner_activity[id][:object_comments] = c
    end
    comments[:partner_comments][:pages].each do |id, c|
      partner_activity[id] ||= { :actions => [], :object_comments => [], :page_comments => [] }
      partner_activity[id][:page_comments] = c
    end
    
    user_activity = {}
    actions[:user_actions].each do |id, a|
      user_activity[id] ||= { :actions => [], :object_comments => [], :page_comments => [] }
      user_activity[id][:actions] = a
    end
    comments[:user_comments][:objects].each do |id, c|
      user_activity[id] ||= { :actions => [], :object_comments => [], :page_comments => [] }
      user_activity[id][:object_comments] = c
    end
    comments[:user_comments][:pages].each do |id, c|
      user_activity[id] ||= { :actions => [], :object_comments => [], :page_comments => [] }
      user_activity[id][:page_comments] = c
    end
    
    return { :partner_activity => partner_activity, :user_activity => user_activity }
  end
  
  def self.all_actions_since_hour(number_of_hours = 24)
    all_action_ids = SpeciesSchemaModel.connection.select_values("
      SELECT id
      FROM #{ActionsHistory.full_table_name} 
      WHERE DATE_ADD(created_at, INTERVAL #{number_of_hours} HOUR) >= NOW()
      AND action_with_object_id IN (#{ActionWithObject.trusted.id}, #{ActionWithObject.untrusted.id}, #{ActionWithObject.inappropriate.id})")
    
    partner_actions = {}
    user_actions = {}
    
    unless all_action_ids.empty?
      # Curator Actions on objects submitted by Content Partners
      result = ActionsHistory.find_by_sql("
        SELECT ah.*, cp.id content_partner_id FROM #{ActionsHistory.full_table_name} ah
        LEFT JOIN (
          #{DataObject.full_table_name} do
          JOIN #{DataObjectsHierarchyEntry.full_table_name} dohe ON (do.id=dohe.data_object_id)
          JOIN #{HierarchyEntry.full_table_name} he ON (dohe.hierarchy_entry_id = he.id)
          JOIN #{Resource.full_table_name} r ON (he.hierarchy_id = r.hierarchy_id)
          JOIN #{AgentsResource.full_table_name} ar ON (r.id = ar.resource_id)
          JOIN #{ContentPartner.full_table_name} cp ON (ar.agent_id = cp.agent_id)
        ) ON (ah.object_id=dohe.data_object_id)
        WHERE ah.id IN (#{all_action_ids.join(',')})
        AND ah.changeable_object_type_id = #{ChangeableObjectType.data_object.id}
        AND cp.id IS NOT NULL
        GROUP BY cp.id, ah.id")
      result.each do |r|
        partner_id = r['content_partner_id'].to_i
        partner_actions[partner_id] ||= []
        partner_actions[partner_id] << r
      end
      
      # Curator Actions on text submitted by Users
      result = ActionsHistory.find_by_sql("
        SELECT ah.*, u.id user_id FROM #{ActionsHistory.full_table_name} ah
        LEFT JOIN (
          #{DataObject.full_table_name} do
          JOIN #{UsersDataObject.full_table_name} udo ON (do.id=udo.data_object_id)
          JOIN #{User.full_table_name} u ON (udo.user_id = u.id)
        ) ON (ah.object_id=udo.data_object_id)
        WHERE ah.id IN (#{all_action_ids.join(',')})
        AND ah.changeable_object_type_id = #{ChangeableObjectType.data_object.id}
        AND u.id IS NOT NULL
        GROUP BY u.id, ah.id")
      result.each do |r|
        user_id = r['user_id'].to_i
        user_actions[user_id] ||= []
        user_actions[user_id] << r
      end
    end
    
    return { :partner_actions => partner_actions, :user_actions => user_actions }
  end
  
  def self.all_comments_since_hour(number_of_hours = 24)
    all_comment_ids = SpeciesSchemaModel.connection.select_values("SELECT id FROM #{Comment.full_table_name} WHERE DATE_ADD(created_at, INTERVAL #{number_of_hours} HOUR) >= NOW()")
    
    partner_comments = { :objects => {}, :pages => {} }
    user_comments = { :objects => {}, :pages => {} }
    
    unless all_comment_ids.empty?
      # Comments left on objects submitted by Content Partners
      result = Comment.find_by_sql("
        SELECT c.*, cp.id content_partner_id FROM #{Comment.full_table_name} c
        LEFT JOIN (
          #{DataObjectsHierarchyEntry.full_table_name} dohe
          JOIN #{HierarchyEntry.full_table_name} he ON (dohe.hierarchy_entry_id = he.id)
          JOIN #{Resource.full_table_name} r ON (he.hierarchy_id = r.hierarchy_id)
          JOIN #{AgentsResource.full_table_name} ar ON (r.id = ar.resource_id)
          JOIN #{ContentPartner.full_table_name} cp ON (ar.agent_id = cp.agent_id)
        ) ON (c.parent_id=dohe.data_object_id)
        WHERE c.id IN (#{all_comment_ids.join(',')})
        AND c.parent_type = 'DataObject'
        AND cp.id IS NOT NULL
        GROUP BY cp.id, c.id")
      result.each do |r|
        partner_id = r['content_partner_id'].to_i
        partner_comments[:objects][partner_id] ||= []
        partner_comments[:objects][partner_id] << r
      end
      
      # Comments left on pages with objects submitted by Content Partners
      result = Comment.find_by_sql("
        SELECT c.*, cp.id content_partner_id FROM #{Comment.full_table_name} c
        LEFT JOIN (
          #{HierarchyEntry.full_table_name} he
          JOIN #{Resource.full_table_name} r ON (he.hierarchy_id = r.hierarchy_id)
          JOIN #{AgentsResource.full_table_name} ar ON (r.id = ar.resource_id)
          JOIN #{ContentPartner.full_table_name} cp ON (ar.agent_id = cp.agent_id)
        ) ON (c.parent_id=he.taxon_concept_id)
        WHERE c.id IN (#{all_comment_ids.join(',')})
        AND c.parent_type = 'TaxonConcept'
        AND cp.id IS NOT NULL
        GROUP BY cp.id, c.id")
      result.each do |r|
        partner_id = r['content_partner_id'].to_i
        partner_comments[:pages][partner_id] ||= []
        partner_comments[:pages][partner_id] << r
      end
      
      
      
      # Comments left on text submitted by Users
      result = Comment.find_by_sql("
        SELECT c.*, u.id user_id FROM #{Comment.full_table_name} c
        LEFT JOIN (
          #{UsersDataObject.full_table_name} udo
          JOIN #{User.full_table_name} u ON (udo.user_id = u.id)
        ) ON (c.parent_id=udo.data_object_id)
        WHERE c.id IN (#{all_comment_ids.join(',')})
        AND c.parent_type = 'DataObject'
        AND u.id IS NOT NULL
        GROUP BY u.id, c.id")
      result.each do |r|
        user_id = r['user_id'].to_i
        user_comments[:objects][user_id] ||= []
        user_comments[:objects][user_id] << r
      end
      
      # Comments left on pages with text submitted by Users
      result = Comment.find_by_sql("
        SELECT c.*, u.id user_id FROM #{Comment.full_table_name} c
        LEFT JOIN (
          #{UsersDataObject.full_table_name} udo
          JOIN #{User.full_table_name} u ON (udo.user_id = u.id)
        ) ON (c.parent_id=udo.taxon_concept_id)
        WHERE c.id IN (#{all_comment_ids.join(',')})
        AND c.parent_type = 'TaxonConcept'
        AND u.id IS NOT NULL
        GROUP BY u.id, c.id")
      result.each do |r|
        user_id = r['user_id'].to_i
        user_comments[:pages][user_id] ||= []
        user_comments[:pages][user_id] << r
      end
    end
    
    return { :partner_comments => partner_comments, :user_comments => user_comments }
  end
end