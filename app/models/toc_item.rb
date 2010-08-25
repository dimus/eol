class TocItem < SpeciesSchemaModel
  
  set_table_name 'table_of_contents'
  acts_as_tree :order => 'view_order'
  
  attr_writer :has_content
  
  has_many :info_items, :foreign_key => :toc_id
  
  has_and_belongs_to_many :data_objects, :join_table => 'data_objects_table_of_contents', :foreign_key => 'toc_id'

  def self.bhl
    cached_find(:label, 'Biodiversity Heritage Library')
  end
  def self.content_partners
    cached_find(:label, 'Content Partners')
  end
  def self.name_and_taxonomy
    cached('names_and_taxonomy') do
      TocItem.find_or_create_by_label('Names and Taxonomy')
    end
  end
  def self.related_names
    cached_find(:label, 'Related Names', self.name_and_taxonomy.id)
  end
  def self.synonyms
    cached('synonyms') do
      TocItem.find_by_label_and_parent_id('Synonyms', self.name_and_taxonomy.id)
    end
  end
  def self.common_names
    cached('common_names') do
      TocItem.find_by_label_and_parent_id('Common Names', self.name_and_taxonomy.id)
    end
  end
  def self.page_statistics
    $CACHE.fetch('toc_items/page_statistics') do
      TocItem.find_or_create_by_label('Page Statistics')
    end
  end
  def self.content_summary
    $CACHE.fetch('toc_items/content_summary') do
      TocItem.find_or_create_by_label('Content Summary')
    end
  end
  def self.overview
    cached_find(:label, 'Overview')
  end
  def self.education
    cached_find(:label, 'Education')
  end
  def self.search_the_web
    cached_find(:label, 'Search the Web')
  end
  def self.biomedical_terms
    cached_find(:label, 'Biomedical Terms')
  end
  def self.literature_references
    cached_find(:label, 'Literature References')
  end
  def self.nucleotide_sequences
    cached_find(:label, 'Nucleotide Sequences')
  end
  def self.wikipedia
    cached_find(:label, 'Wikipedia')
  end
  
  
  
  def is_child?
    !(self.parent_id.nil? or self.parent_id == 0) 
  end

  def allow_user_text?
    self.info_items.length > 0 && !["Wikipedia", "Barcode"].include?(self.label)
  end
  
  def self.selectable_toc
    TocItem.find_by_sql("SELECT toc.* FROM table_of_contents toc JOIN info_items ii ON (toc.id=ii.toc_id) WHERE toc.label NOT IN ('Wikipedia', 'Barcode') ORDER BY toc.label").uniq.collect {|c| [c.label, c.id] }
  end

  def wikipedia?
    self.label == "Wikipedia" 
  end
  
  def self.roots
    TocItem.find_all_by_parent_id(0, :order => 'view_order', :include => :info_items)
  end
  
  def children
    TocItem.find_all_by_parent_id(self.id, :order => 'view_order', :include => :info_items)
  end
  
  def self.whole_tree
    TocItem.all(:order => 'view_order', :include => :info_items)
  end
  
  def add_child(new_label)
    return if new_label.blank?
    return unless is_major?
    max_view_order = TocItem.connection.select_values("SELECT max(view_order) FROM table_of_contents WHERE id=#{id} OR parent_id=#{id}")[0].to_i
    next_view_order = max_view_order + 1
    TocItem.connection.execute("UPDATE table_of_contents SET view_order=view_order+1 WHERE view_order >= #{next_view_order}")
    TocItem.create(:label => new_label, :parent_id => id, :view_order => next_view_order)
  end
  def self.add_major_chapter(new_label)
    return if new_label.blank?
    max_view_order = TocItem.connection.select_values("SELECT max(view_order) FROM table_of_contents")[0].to_i
    next_view_order = max_view_order + 1
    TocItem.create(:label => new_label, :parent_id => 0, :view_order => next_view_order)
  end
  
  # I suppose we just need a move_up method and move_down could fire off a move_up to its next chapter
  # but having two methods will save a few queries
  def move_down
    if is_major?
      if chapter_after = next_major_chapter
        to_subtract = chapter_length
        TocItem.connection.execute("UPDATE table_of_contents SET view_order=view_order+#{chapter_after.chapter_length} WHERE id=#{id} OR parent_id=#{id}")
        TocItem.connection.execute("UPDATE table_of_contents SET view_order=view_order-#{to_subtract} WHERE id=#{chapter_after.id} OR parent_id=#{chapter_after.id}")
      end
    else  # sub chapter
      new_view_order = view_order + 1
      if next_toc = TocItem.find_by_view_order(new_view_order)
        if next_toc.is_sub?
          next_toc.view_order = view_order
          next_toc.save
          self.view_order = new_view_order
          self.save
        end
      end
    end
  end
  
  def move_up
    if is_major?
      if chapter_before = previous_major_chapter
        to_add = chapter_length
        TocItem.connection.execute("UPDATE table_of_contents SET view_order=view_order-#{chapter_before.chapter_length} WHERE id=#{id} OR parent_id=#{id}")
        TocItem.connection.execute("UPDATE table_of_contents SET view_order=view_order+#{to_add} WHERE id=#{chapter_before.id} OR parent_id=#{chapter_before.id}")
      end
    else  # sub chapter
      new_view_order = view_order - 1
      if previous_toc = TocItem.find_by_view_order(new_view_order)
        if previous_toc.is_sub?
          previous_toc.view_order = view_order
          previous_toc.save
          self.view_order = new_view_order
          self.save
        end
      end
    end
  end
  
  def previous_major_chapter
    result = TocItem.find_by_sql("SELECT * FROM table_of_contents WHERE view_order<#{view_order} AND parent_id=0 ORDER BY view_order DESC")
    return nil if result.blank?
    result[0]
  end
  def next_major_chapter
    result = TocItem.find_by_sql("SELECT * FROM table_of_contents WHERE view_order>#{view_order} AND parent_id=0 ORDER BY view_order ASC")
    return nil if result.blank?
    result[0]
  end
  def chapter_length
    return nil if parent_id != 0
    if next_chapter = next_major_chapter
      return next_chapter.view_order - view_order
    end
    return TocItem.count_by_sql("SELECT COUNT(*) FROM table_of_contents WHERE id=#{id} OR parent_id=#{id}")
  end
  def is_major?
    return parent_id == 0
  end
  def is_sub?
    return parent_id != 0
  end
  
  def self.last_major_chapter
    TocItem.find_all_by_parent_id(0, :order => 'view_order desc')[0]
  end
end

# == Schema Info
# Schema version: 20081020144900
#
# Table name: table_of_contents
#
#  id         :integer(2)      not null, primary key
#  parent_id  :integer(2)      not null
#  label      :string(255)     not null
#  view_order :integer(1)      not null

