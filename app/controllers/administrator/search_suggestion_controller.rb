class Administrator::SearchSuggestionController < AdminController

  layout 'left_menu'

  before_filter :set_layout_variables

  helper :resources

  access_control :site_cms
  
  def index
    @page_title = I18n.t("search_suggestions")
    @term_search_string = params[:term_search_string] || ''
    search_string_parameter = '%' + @term_search_string + '%' 
    # let us go back to a page where we were
    page = params[:page] || "1"
    @search_suggestions = SearchSuggestion.paginate(
      :conditions => ['term like ? OR scientific_name like ?', search_string_parameter, search_string_parameter],
      :order => 'term asc', :page => page)
    @search_suggestions_count=SearchSuggestion.count(
      :conditions => ['term like ? OR scientific_name like ?', search_string_parameter, search_string_parameter])
  end

  def new
    @page_title = I18n.t("new_search_suggestion")
    @search_suggestion = SearchSuggestion.new
    store_location(referred_url) if request.get?    
  end

  def edit
    @page_title = I18n.t("edit_search_suggestion")
    @search_suggestion = SearchSuggestion.find(params[:id])
    store_location(referred_url) if request.get?    
  end

  def create
    @search_suggestion = SearchSuggestion.new(params[:search_suggestion])
    @search_suggestion.scientific_name, @search_suggestion.common_name, @search_suggestion.image_url = get_names_and_image(params[:search_suggestion][:taxon_id])
    if @search_suggestion.save
      flash[:notice] = I18n.t("the_search_suggestion_was_succ")
      redirect_back_or_default(url_for(:action => 'index'))
    else
      render :action => "new" 
    end
  end

  def update
    @search_suggestion = SearchSuggestion.find(params[:id])
    if @search_suggestion.update_attributes(params[:search_suggestion])
      flash[:notice] = I18n.t("the_search_suggestion_was_succ_")
      redirect_back_or_default(url_for(:action => 'index'))
    else
      render :action => "edit" 
    end
  end

  def destroy
    (redirect_to referred_url;return) unless request.method == :delete
    @search_suggestion = SearchSuggestion.find(params[:id])
    @search_suggestion.destroy
    redirect_to referred_url 
  end

  # ajax call to update name and image for a given taxon_id
  def update_names_and_image
    scientific_name, common_name, image_url = get_names_and_image(params[:taxon_id])
    render :update do |page|
      page << "$('#search_suggestion_scientific_name').val('#{scientific_name}');"
      page << "$('#search_suggestion_common_name').val('#{common_name}');"
      page << "$('#search_suggestion_image_url').val('#{image_url}');"
    end
  end

private 

  def get_names_and_image(taxon_concept_id)
    scientific_name = ''
    common_name = ''
    image_url = ''
    unless taxon_concept_id.blank?
      taxon_concept = TaxonConcept.find_by_id(taxon_concept_id)
      unless taxon_concept.nil?
        scientific_name = taxon_concept.entry.italicized_name
        common_name = taxon_concept.common_name
        images = taxon_concept.images
        image_url = DataObject.image_cache_path(images[0].object_cache_url, :medium) unless (images.nil? || images[0].nil?)
      end
    end
    return scientific_name, common_name, image_url
  end

  def set_layout_variables
    @page_title = $ADMIN_CONSOLE_TITLE
    @navigation_partial = '/admin/navigation'
  end

end
