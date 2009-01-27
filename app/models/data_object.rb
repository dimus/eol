# Represents any kind of object imported from a ContentPartner, eg.
# am image, article, video, etc
require 'set'
class DataObject < SpeciesSchemaModel

  belongs_to :data_type
  belongs_to :license
  belongs_to :mime_type
  belongs_to :visibility
  belongs_to :vetted
  
	has_many :top_images
  has_many :languages
  has_many :agents_data_objects, :include => [ :agent, :agent_role ]
  has_many :data_objects_taxa
  has_many :comments, :as => :parent, :attributes => true
  has_many :data_objects_harvest_events
  has_many :harvest_events, :through => :data_objects_harvest_events
  has_many :agents, :through => :agents_data_objects
  has_many :resources, :through => :taxa
  has_many :data_object_tags, :class_name => DataObjectTags.to_s
  has_many :tags, :class_name => DataObjectTag.to_s, :through => :data_object_tags, :source => :data_object_tag
  has_many :data_objects_table_of_contents

  has_and_belongs_to_many :taxa
  has_and_belongs_to_many :info_items
  has_and_belongs_to_many :audiences
  has_and_belongs_to_many :refs
  has_and_belongs_to_many :agents
  has_and_belongs_to_many :toc_items, :join_table => 'data_objects_table_of_contents', :association_foreign_key => 'toc_id'

  attr_accessor :vetted_by # who changed the state of this object? (not persisted on DataObject but required by observer)
  
  named_scope :visible, lambda { { :conditions => { :visibility_id => Visibility.visible.id } }}
  named_scope :preview, lambda { { :conditions => { :visibility_id => Visibility.preview.id } }}

  # comment on this
  def comment(user, body)
    comment = comments.create :user_id => user.id, :body => body
    user.comments.reload # be friendly - update the user's comments automatically
    return comment
  end

  def is_curatable_by? user
    ( hierarchy_entries.collect {|entry| user.can_curate? entry } ).include? true
  end
  
  # TODO - this is broken, but unused.  When we start using it again, it must be fixed.
  def self.images_for_hierarchy_entry(he_id)
    # NOTE - left join on the licenses, so they could be NULL.
    # (But we don't want to miss images with no license!)
    # TODO - MED PRIORITY - I'm assuming there's one HE for this data object, and there could be several.
    DataObject.find_by_sql([%q{SELECT DISTINCT do.*, l.description license_text, l.logo_url license_logo, l.source_url license_url,
                                      hierarchy_entry_id taxon_id, t.scientific_name
                                FROM top_images ti JOIN hierarchy_entry_names hen USING (hierarchy_entry_id)
                                  JOIN data_objects do        ON ti.data_object_id = do.id
                                  JOIN data_objects_taxa dot  ON do.id = dot.data_object_id
                                  JOIN taxa t                 ON dot.taxon_id = t.id
                                  LEFT OUTER JOIN licenses l  ON do.license_id = l.id 
                                WHERE hierarchy_entry_id = ? AND data_type_id IN (?) AND visibility_id = 1
                                ORDER BY ti.view_order     # images_for_hierarchy_entry },
                            he_id, DataType.image_type_ids])
  end

  def data_supplier_agent
    Agent.find_by_sql(["select a.* from data_objects_harvest_events dohe join harvest_events he on (dohe.harvest_event_id=he.id) join agents_resources ar on (he.resource_id=ar.resource_id) join agents a on (ar.agent_id=a.id) where dohe.data_object_id=? and ar.resource_agent_role_id=3", self.id]).first
  end
  
  # gets agents_data_objects, sorted by AgentRole, based on this objects' DataTypes' AgentRole attribution priorities
  #
  # we also fetch agents_data_objects, including (eager loading) Agents by default, assuming we will be using them
  #
  # TODO clean this up.  needs to be broken down into different methods.  this was clean until we added abunchof denormalizations
  def attributions
    # for each of the agent roles in the attribution order, go thru agents_data_objects and 
    # get all of the agents in that role => [ [role1, role1], nil, [role3], [role4], nil ]
    grouped_by_agent_role = data_type.full_attribution_order.inject([]) do |all, agent_role|
      all << agents_data_objects.select {|ado| ado.agent_role == agent_role }
      all
    end
    
    # get rid of nils and sort the groups by view_order
    grouped_by_agent_role.compact!
    grouped_by_agent_role.each_with_index do |group, i|
      grouped_by_agent_role[i] = group.sort_by {|g| g.view_order }
    end

    # now, go through and put everything into 1 ordered list, no longer grouped
    grouped_by_agent_role = grouped_by_agent_role.inject([]) do |all, sorted_group|
      all += sorted_group
      all
    end

    # we need to manually add the Data Supplier too ... TODO extract these custom things into the full_attribution_order method (or something?)
    supplier = data_supplier_agent
    if supplier
      index_to_insert_data_supplier = 0
      while grouped_by_agent_role[index_to_insert_data_supplier] and grouped_by_agent_role[index_to_insert_data_supplier].agent_role == AgentRole[:Author]
        index_to_insert_data_supplier += 1
      end
      grouped_by_agent_role.insert index_to_insert_data_supplier, AgentsDataObject.new( :agent => supplier, 
                                                              :agent_role => AgentRole.new(:label => 'Supplier'), :view_order => 0 )
    end

    # now, we need to go in and put the rights statement ... this is very hacky but the 
    # rights statement is supposed to show up after the Source, but it's not actually an attribution
    # so ... we have to stick it into the list somehow for it to show up  :/
    # 
    # it should show up *after* Source, if it exists, else Author, else it should show up first
    #
    #
    # TODO this needs some serious cleanup
    #
    a_license = self.license
    a_license ||= License.find_by_title('public domain') # if there's no license, we wanna display the 'No right reserved' license (aka public domain)
    unless rights_statement.empty? && a_license.nil?
      roles_to_insert_after = AgentRole[ :Author, :Source ]
      index_to_insert_rights = 0
      # logo_cache_url isn't working, nor is logo_url  :(
      rights_agent  = Agent.new :project_name => (rights_statement.empty? ? a_license.description : "#{rights_statement} #{a_license.description}"), 
                                :homepage => a_license.source_url, :logo_url => a_license.logo_url, :logo_cache_url => 0, 
                                :logo_file_name => a_license.logo_url # <-- check for the presence of logo_file name
      rights_object = AgentsDataObject.new :agent => rights_agent, :agent_role => AgentRole.new(:label => 'Copyright'), :view_order => 0
      grouped_by_agent_role.each_with_index do |group, i|
        index_to_insert_rights = i + 1 if roles_to_insert_after.include? group.agent_role
      end
      grouped_by_agent_role.insert index_to_insert_rights, rights_object
    end

    # we ALSO need Location
    unless location.empty?
      grouped_by_agent_role << AgentsDataObject.new( :agent => Agent.new(:project_name => location), :agent_role => AgentRole.new(:label => 'Location'), :view_order => 0 )
    end
    
    # we ALSO need the source_url
    unless source_url.empty?
      grouped_by_agent_role << AgentsDataObject.new( :agent => Agent.new(:project_name => 'View original data object', :homepage => source_url), 
                                                    :agent_role => AgentRole.new(:label => 'Source URL'), :view_order => 0 )
    end

    # ... bibliographic_citation ...
    unless bibliographic_citation.empty?
      grouped_by_agent_role << AgentsDataObject.new( :agent => Agent.new(:project_name => bibliographic_citation), :agent_role => AgentRole.new(:label => 'Citation'), :view_order => 0 )
    end

    grouped_by_agent_role
  end

  def authors
    default_authors = agents_data_objects.find_all_by_agent_role_id(AgentRole.author_id).collect {|ado| ado.agent }.compact
    @fake_authors.nil? ? default_authors : default_authors + @fake_authors
  end

  def photographers
    default_photographers = agents_data_objects.find_all_by_agent_role_id(AgentRole.photographer_id).collect {|ado| ado.agent }.compact
    @fake_photographers.nil? ? default_photographers : default_photographers + @fake_photographers
  end
  
  def fake_author(author_options)
    @fake_authors ||= []
    @fake_authors << Agent.new(author_options)
  end

  def sources
    list = agents_data_objects.find_all_by_agent_role_id(AgentRole.source_id).collect {|ado| ado.agent }.compact
    return list unless list.blank?
    # I ended up with empty lists in cases where I thought I shouldn't, so tried to defer to authors for those:
    return authors
  end

  def visible_comments(user = nil)
    return comments if (not user.nil?) and user.is_moderator?
    comments.find_all {|comment| comment.visible? }
  end

  def image?
    return DataType.image_type_ids.include?(data_type_id)
  end
  
  def map?
    return DataType.map_type_ids.include?(data_type_id)
  end
  
  def text?
    return DataType.text_type_ids.include?(data_type_id)
  end
  
  def self.cache_path(cache_url, subdir = $CONTENT_SERVER_CONTENT_PATH)
    (ContentServer.next + subdir +
      cache_url.to_s.gsub(/(\d{4})(\d{2})(\d{2})(\d{2})(\d+)/, "/\\1/\\2/\\3/\\4/\\5"))
  end

  def self.image_cache_path(cache_url, size = :large, subdir = $CONTENT_SERVER_CONTENT_PATH)
    self.cache_path(cache_url, subdir) + "_#{size}.#{$SPECIES_IMAGE_FORMAT}"
  end

  def has_thumbnail_cache?
    return false if thumbnail_cache_url.blank? or thumbnail_cache_url == 0
    return true
  end
  
  def has_object_cache_url?
    return false if object_cache_url.blank? or object_cache_url == 0
    return true
  end

  def thumb_or_object(size = :large)
    return DataObject.image_cache_path(object_cache_url, size) 
  end

  def smart_thumb
    thumb_or_object(:small)
  end
  
  def smart_medium_thumb
    thumb_or_object(:medium)
  end
  
  def smart_image
    thumb_or_object
  end  

  def video_url
    if data_type.label == 'Flash'
      return has_object_cache_url? ? DataObject.cache_path(object_cache_url) + '.flv' : ''
    else
      return object_url
    end
  end

  def map_image
    # Sometimes, we want to serve map images right from the source:
    if ($PREFER_REMOTE_IMAGES and not object_url.blank?) or (object_cache_url.blank?)
      return object_url
    else
      return DataObject.cache_path(object_cache_url) + "_orig.jpg"
    end
  end

  # tag with a DataObjectTag
  def tag(key, values, user = nil)
    DataObject.tag self, key, values, user
  end

  def public_tags
    DataObjectTags.public_tags_for_data_object self
  end

  def private_tags user
    DataObjectTags.private_tags.find_all_by_data_object_id_and_user_id id, user.id
  end

  alias user_tags private_tags
  alias users_tags private_tags
  

  # Names of taxa associated with this image
  def taxa_names_taxon_concept_ids
    taxa=Taxon.find_by_sql("select t.scientific_name as taxon_name, tcn.taxon_concept_id as taxon_concept_id from data_objects_taxa dot join taxa t on (dot.taxon_id=t.id) join taxon_concept_names tcn on (t.name_id=tcn.name_id) where data_object_id=#{self.id} group by t.id")
    taxa.map{|t| {:taxon_name => t.taxon_name, :taxon_concept_id => t.taxon_concept_id}}
  end


  # returns a hash in the format { 'tag_key' => ['value1','value2'] }
  def tags_hash
    tags.inject({}) do |all,this|
      all[this.key] = (all[this.key] || []) + [this.value]
      all
    end
  end

  # returns an array of all of the keys an object is tagged with
  def tag_keys
    tags.map {|t| t.key }.uniq
  end

  # return all of the taxon concepts associated with this DataObject
  def taxon_concepts
    # need to optimize with eager loading
    @taxon_concepts ||= DataObjectsTaxon.find_all_by_data_object_id(id).map(&:taxon).inject([]){|all,this_taxon| ( all + this_taxon.taxon_concepts ) }.uniq
  end

  # this is even less efficient than #taxon_concepts - OPTIMIZE!
  def hierarchy_entries
    @hierarchy_entries ||= taxon_concepts.inject([]){|all,concept| all + concept.hierarchy_entries  }.uniq
  end
  
  def curate!(action)
    activity = CuratorActivity.find(action)

    if activity.code[/^approve$/i]
      vet!
    elsif activity.code[/^disapprove$/i]
      unvet!
    elsif activity.code[/^show$/i]
      show!
    elsif activity.code[/^hide$/i]
      hide!
    elsif activity.code[/^inappropriate$/i]
      inappropriate!
    else
      raise "Not sure how to #{activity.code} a DataObject"
    end
  end
  
  def curated?
    self.curated
  end

  def visible?
    visibility_id == Visibility.visible.id
  end
  def invisible?
    visibility_id == Visibility.invisible.id
  end
  def inappropriate?
    visibility_id == Visibility.inappropriate.id
  end
  
  def untrusted?
    vetted_id == Vetted.untrusted.id
  end
  
  def unknown?
    vetted_id == Vetted.unknown.id
  end

  def vetted?
    vetted_id == Vetted.trusted.id
  end
  alias is_vetted? vetted?
  alias trusted? vetted?

  def show! user = nil
    self.vetted_by = user if user
    update_attributes({:visibility_id => Visibility.visible.id, :curated => true})
  end
  def hide! user = nil
    self.vetted_by = user if user
    update_attributes({:visibility_id => Visibility.invisible.id, :curated => true})
  end
  def vet! user = nil
    self.vetted_by = user if user
    update_attributes({:vetted_id => Vetted.trusted.id, :curated => true})
  end
  def unvet! user = nil
    self.vetted_by = user if user
    update_attributes({:vetted_id => Vetted.untrusted.id, :curated => true})
  end
  def inappropriate! user = nil
    self.vetted_by = user if user
    update_attributes({:visibility_id => Visibility.inappropriate.id, :curated => true})
  end

  def to_s
    "[DataObject id:#{id}]"
  end

  # Find data objects tagged with a particular tag
  #
  # If no 'value' is provided for the tag, it will find all data objects
  # tagged with *any* value of the given key (category)
  #
  # Usage:
  #   DataObject.search_by_tag :color, 'blue'
  #   DataObject.search_by_tag :color, :blue
  #   DataObject.search_by_tag <DataObjecTag>
  #
  # TODO this is starting to get really messy ... extract some of this outta here into objects ...
  #      try a named_scope on TopImage and things like that ... move to other models or to other
  #      DataObject methods
  #
  def self.search_by_tag key_or_tag, value_or_nil = nil, options = {}
    tag = (key_or_tag.is_a?DataObjectTag) ? key_or_tag : DataObjectTag[key_or_tag, value_or_nil]
    data_object_tags = (tag) ? DataObjectTags.search_by_tag( tag ) : []
    return [] if data_object_tags.empty?
    if options[:clade]
      options[:clade] = [ options[:clade] ] unless options[:clade].is_a?Array
      data_object_ids = data_object_tags.map(&:data_object_id).uniq
      clades = HierarchyEntry.find :all, :conditions => options[:clade].map {|id| "id = #{id}" }.join(' OR ')
      return [] if clades.empty?
      sql = %[
        SELECT DISTINCT top_images.data_object_id
        FROM top_images 
        JOIN hierarchy_entries ON top_images.hierarchy_entry_id = hierarchy_entries.id
        WHERE ]
      sql += clades.map {|clade| "(hierarchy_entries.lft >= #{clade.lft} AND hierarchy_entries.lft <= #{clade.rgt})" }.join(' OR ')
      sql += %[ AND data_object_id IN (#{data_object_ids.join(',')})]
      tagged_images_in_clade = TopImage.find_by_sql sql
      tagged_images_in_clade.map {|img| DataObject.find(img.data_object_id) }.uniq
    else
      data_object_tags.map(&:object).uniq
    end
  end

  # Find data objects tagged with certain tags
  #
  # Usage:
  #   DataObject.search_by_tags [ [<DataObjecTag>], [<DataObjectTag>, <DataObjectTag] ]
  #   DataObject.search_by_tags [ [[:key1,'value1']], [[:key2,:value2],['key3',:value3]] ]
  #
  # TODO: Optimization is necessary, the way it is now is quite resource hungry
  def self.search_by_tags tags, options = {}
    t = tags.inject([]) do |res,tags_group|
      if tags_group.first.is_a?(DataObjectTag)
        res << tags_group
      else
        res << tags_group.map {|k,v| DataObjectTag[k,v]}
      end
    end
    result = t.inject(Set.new) do |res, tags_group|
      search = (DataObject.search_tags_group(tags_group, options).to_set)
      res = res ? search : res.intersection(search)
    end.to_a
    result
  end

  def self.search_tags_group tags, options
    tags.compact!
    return [] if tags.empty?
    data_object_tags = DataObjectTags.search_by_tags_or tags, options[:user_id]
    return [] if data_object_tags.empty?

    if options[:clade]

      # TODO - THIS HAS BEEN COPY/PASTED - ***JUST*** FOR TESTING - NEEDS REFACTORING & TO BE DRY'd UP
      options[:clade] = [ options[:clade] ] unless options[:clade].is_a?Array
      data_object_ids = data_object_tags.map(&:data_object_id).uniq
      clades = HierarchyEntry.find :all, :conditions => options[:clade].map {|id| "id = #{self.id}" }.join(' OR ')
      return [] if clades.empty?
      sql = %[
        SELECT DISTINCT top_images.data_object_id
        FROM top_images 
        JOIN hierarchy_entries ON top_images.hierarchy_entry_id = hierarchy_entries.id
        WHERE ]
      sql += clades.map {|clade| "(hierarchy_entries.lft >= #{clade.lft} AND hierarchy_entries.lft <= #{clade.rgt})" }.join(' OR ')
      sql += %[ AND data_object_id IN (#{data_object_ids.join(',')})]
      tagged_images_in_clade = TopImage.find_by_sql sql
      return tagged_images_in_clade.map {|img| DataObject.find(img.data_object_id) }.uniq

    else
      return data_object_tags.map(&:object).uniq
    end
  end

  def self.cached_images_for_taxon(taxon, options = {})
    options[:user] = User.create_new if options[:user].nil?
    if options[:from].nil?
      options[:from] ||= 'top_images'
    else
      nested = true
    end
    join_agents = options[:agent].nil?  ? '' : self.join_agents_clause(options[:agent]) if
        nested
    # NOTE - left join on the licenses, so they could be NULL.
    # (But we don't want to miss images with no license!)
    
    #pp options
    
    result=DataObject.find_by_sql([%Q{SELECT dato.*, l.description license_text, l.logo_url license_logo, l.source_url license_url,
                                      (?) taxon_id, t.scientific_name
                                FROM #{options[:from]} ti
                                  STRAIGHT_JOIN data_objects dato      ON ti.data_object_id = dato.id
                                  STRAIGHT_JOIN data_objects_taxa dot  ON dato.id = dot.data_object_id
                                  STRAIGHT_JOIN taxa t                 ON dot.taxon_id = t.id
                                  #{join_agents}
                                  LEFT JOIN licenses l        ON dato.license_id = l.id 
                                WHERE ti.hierarchy_entry_id IN (?)
                                  AND data_type_id IN (?)
                                  #{DataObject.visibility_clause(options.merge(:taxon => taxon))}
                                  GROUP BY dato.id
                                ORDER BY dato.vetted_id DESC,dato.data_rating                          # DataObject.cached_images_for_taxon },
                            taxon.id, taxon.hierarchy_entries.collect {|he| he.id }, DataType.image_type_ids])                            
    # Run a second query if we need unpublished or invisible images (but not if we're already doing it!!!):
    if not nested and ((not options[:agent].nil?) or options[:user].is_curator? or options[:user].is_admin?)
      result += DataObject.cached_images_for_taxon(taxon, options.merge(:from => 'top_unpublished_images'))
    end
    taxon.includes_unvetted = true if result.detect {|d| d.vetted_id != Vetted.trusted.id }
    return result                            
  end

  def self.for_taxon(taxon, type, options = {})
    options[:user] = User.create_new if options[:user].nil?
    
    # Just return the (much faster) cached images if there is no need to deal with permissions:
    # TODO - does this next line need to move to the bottom, to ADD these images?  I think not, but we should check.
    return DataObject.cached_images_for_taxon(taxon, options) if type == :image
    klass = (type == :text && options[:toc_id].nil?) ? TocItem : DataObject
    # puts "---- BIG QUERY " + '-' * 40
    # puts DataObject.build_query(taxon, type, options)
    # puts '-' * 60
    results = klass.find_by_sql(DataObject.build_query(taxon, type, options))
    taxon.includes_unvetted = true if results.detect {|d| d.vetted_id != Vetted.trusted.id }
    return results
  end

  # TODO - MED PRIORITY - I'm assuming there's one taxa for this data object, and there could be several.
  # TODO = licenses should simply be included, and referenced directly where needed.
  def self.build_query(taxon, type, options)
    add_toc      = (type == :text and options[:toc_id].nil?) ? ', toc.*' : ''
    join_agents  = options[:agent].nil?  ? '' : self.join_agents_clause(options[:agent])
    join_toc     = type == :text         ? 'JOIN data_objects_table_of_contents dotoc ON dotoc.data_object_id = dato.id ' +
                                                 'JOIN table_of_contents toc ON toc.id = dotoc.toc_id' : ''
    where_toc    = options[:toc_id].nil? ? '' : ActiveRecord::Base.sanitize_sql(['AND toc.id = ?', options[:toc_id]])
    sort         = 'dato.published, dato.vetted_id DESC, dato.data_rating' # unpublished first, then by data_rating.

    ActiveRecord::Base.sanitize_sql([<<EOVIDEOSQL, taxon.id, DataObject.get_type_ids(type)])

SELECT DISTINCT dt.label media_type, dato.*, t.scientific_name, tcn.taxon_concept_id taxon_id,
       l.description license_text, l.logo_url license_logo, l.source_url license_url #{add_toc}
  FROM taxon_concept_names tcn
    STRAIGHT_JOIN taxa t                ON (tcn.name_id = t.name_id)
    STRAIGHT_JOIN data_objects_taxa dot ON (t.id = dot.taxon_id)
    STRAIGHT_JOIN data_objects dato     ON (dot.data_object_id = dato.id)
    STRAIGHT_JOIN data_types dt         ON (dato.data_type_id = dt.id)
    #{join_agents} #{join_toc}
    LEFT OUTER JOIN licenses l       ON (dato.license_id = l.id)
  WHERE tcn.taxon_concept_id = ?
    AND data_type_id IN (?)
    #{DataObject.visibility_clause(options.merge(:taxon => taxon))}
    #{where_toc}
  ORDER BY #{sort} # DataObject.for_taxon

EOVIDEOSQL

  end

private

  def self.join_agents_clause(agent)
    data_supplier_id = ResourceAgentRole.content_partner_upload_role.id
    return %Q{LEFT JOIN (agents_resources ar
              STRAIGHT_JOIN harvest_events he ON ar.resource_id = he.resource_id
                  AND ar.agent_id = #{agent.id}
                  AND ar.resource_agent_role_id = #{data_supplier_id}
              STRAIGHT_JOIN data_objects_harvest_events dohe ON he.id = dohe.harvest_event_id)
                ON (dato.id = dohe.data_object_id)}
  end

  def self.visibility_clause(options)
    preview_objects = ActiveRecord::Base.sanitize_sql(['OR (dato.visibility_id = ? AND dato.published IN (0,1))', Visibility.preview.id])
    published    = [1] # Boolean
    vetted       = [Vetted.trusted.id]
    visibility   = [Visibility.visible.id]
    other_visibilities = ''
    if options[:user]
      if options[:user].is_curator? and options[:user].can_curate?(options[:taxon])
        vetted += [Vetted.untrusted.id, Vetted.unknown.id] if options[:user].show_unvetted?
        visibility << Visibility.invisible.id
      end
      if options[:user].is_admin?
        vetted += [Vetted.untrusted.id, Vetted.unknown.id]
        visibility = Visibility.all_ids
        other_visibilities = preview_objects
      end
      if options[:user].vetted == false
        vetted += [Vetted.unknown.id,Vetted.untrusted.id]
      end
    end
    if options[:agent] # Content partner ... note that some of this is handled via the join in join_agents_clause().
      visibility << Visibility.invisible.id
      vetted += [Vetted.untrusted.id, Vetted.unknown.id]
      other_visibilities = preview_objects
    end

    return ActiveRecord::Base.sanitize_sql([<<EOVISBILITYCLAUSE, vetted.uniq, published, visibility])
    AND dato.vetted_id IN (?)
    AND ((dato.published IN (?)
      AND dato.visibility_id IN (?)) #{other_visibilities})
EOVISBILITYCLAUSE
  end

  def self.get_type_ids(type)
    case type
    when :map 
      return DataType.map_type_ids
    when :text 
      return DataType.text_type_ids
    when :video 
      return DataType.video_type_ids
    when :image 
      return DataType.image_type_ids
    else
      raise "I'm not sure what data type #{type} is."
    end
  end

  # TODO - this isn't used yet and hasn't been kept up to date with the above.
  def self.for_hierarchy_entry(entry_id, type)
    # There can be more than one of these; we take the first (note the [0])
    # TEST - make sure the visible actually works; we also removed HE--just using concepts ... also, the video_type -> data_type,
    # so we'll need to change that where it's used.
    DataObject.find_by_sql([<<EOVIDEOSQL, entry_id, type == :map ? DataType.map_type_ids : DataType.video_type_ids])
    
    SELECT dt.label media_type, dato.*, t.scientific_name,
           t.scientific_name, tcn.taxon_concept_id taxon_id,
           l.description license_text, l.logo_url license_logo, l.source_url license_url
      FROM taxon_concept_names tcn
        INNER JOIN taxa t                    ON (tcn.name_id = t.name_id)
        INNER JOIN data_objects_taxa dot     ON (t.id = dot.taxon_id)
        INNER JOIN data_objects dato         ON (dot.data_object_id = dato.id)
        INNER JOIN data_types dt             ON (dato.data_type_id = dt.id)
        LEFT OUTER JOIN licenses l           ON (dato.license_id = l.id)
      WHERE tcn.source_hierarchy_entry_id = (?) AND data_type_id IN (?) AND
        dato.visibility_id = 1
      ORDER BY dato.data_rating  # DataObject.for_hierarchy_entry

EOVIDEOSQL
  end

  # add a DataObjectTag to a DataObject
  #
  # returns true is a tag was successfully added, else false
  def self.tag data_object, key, values, user = nil
    values = [values.to_s] unless values.is_a?Array
    results = []
    if data_object and key and values
      values.each do |value|
        tag    = DataObjectTag.find_or_create_by_key_and_value key.to_s, value.to_s
        join   = DataObjectTags.new :data_object => data_object, :data_object_tag => tag, :user => user
        results << join.save
      end
      data_object.tags.reset
      user.tags.reset if user
    end
    ( ! results.include?false ) # return true or false based on whether the new tag association was created OK
  end
  
end
# == Schema Info
# Schema version: 20081020144900
#
# Table name: data_objects
#
#  id                     :integer(4)      not null, primary key
#  data_type_id           :integer(2)      not null
#  language_id            :integer(2)      not null
#  license_id             :integer(1)      not null
#  mime_type_id           :integer(2)      not null
#  vetted_id              :integer(1)      not null
#  visibility_id          :integer(4)
#  altitude               :float           not null
#  bibliographic_citation :string(300)     not null
#  curated                :boolean(1)      not null
#  data_rating            :float           not null
#  description            :text            not null
#  guid                   :string(32)      not null
#  latitude               :float           not null
#  location               :string(255)     not null
#  longitude              :float           not null
#  object_cache_url       :string(255)     not null
#  object_title           :string(255)     not null
#  object_url             :string(255)     not null
#  published              :boolean(1)      not null
#  rights_holder          :string(255)     not null
#  rights_statement       :string(300)     not null
#  source_url             :string(255)     not null
#  thumbnail_cache_url    :string(255)     not null
#  thumbnail_url          :string(255)     not null
#  created_at             :timestamp       not null
#  object_created_at      :timestamp       not null
#  object_modified_at     :timestamp       not null
#  updated_at             :timestamp       not null

