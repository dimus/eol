require File.dirname(__FILE__) + '/../spec_helper'
require 'nokogiri'

class TaxonConcept
  def self.missing_id
    missing_id = TaxonConcept.last.id + 1
    while(TaxonConcept.exists?(missing_id)) do
      missing_id += 1
    end
    missing_id
  end
end

describe 'Taxa overview' do

  before(:all) do

    truncate_all_tables
    load_scenario_with_caching(:testy)
    @testy = EOL::TestInfo.load('testy')
    Capybara.reset_sessions!
    HierarchiesContent.delete_all
    @section = 'overview'

  end

  context 'when taxon has all expected data' do
    before(:all) { visit("pages/#{@testy[:id]}") }
    subject { body }
    # WARNING: Regarding use of subject, if you are using with_tag you must specify body.should... due to bug.
    # @see https://rspec.lighthouseapp.com/projects/5645/tickets/878-problem-using-with_tag

    it 'should show the taxon name and section name in the content header area' do
      should have_tag('div#content_header_container h1', /^(#{@testy[:scientific_name]})(\n|.)*?(#{@section})$/i)
    end
    it 'should show the preferred common name in the content header area' do
      should have_tag('div#content_header_container p', /^#{@testy[:common_name]}/)
    end
    it 'should show a link to common names with count' do
      should have_tag('div#content_header_container a', /^#{@testy[:taxon_concept].common_names.count}/)
    end
    it 'should show a gallery of four images' do
      body.should have_tag("div#image_summary_gallery_container") do
        with_tag("img[src$=#{@testy[:taxon_concept].images[0].smart_thumb[25..-1]}]")
        with_tag("img[src$=#{@testy[:taxon_concept].images[1].smart_thumb[25..-1]}]")
        with_tag("img[src$=#{@testy[:taxon_concept].images[2].smart_thumb[25..-1]}]")
        with_tag("img[src$=#{@testy[:taxon_concept].images[3].smart_thumb[25..-1]}]")
      end
      should_not have_tag("img[src$=#{@testy[:taxon_concept].images[4].smart_thumb[25..-1]}]")
    end
    it 'should have sanitized descriptive text alternatives for images in gallery'
      # TODO - figure out how to add html to testy image description so can test sanitaztion of alt tags
      # should have_tag('div#image_summary_gallery_container img[alt^=?]', /(\w+\s){5}/, { :count => 4 })
    it 'should show IUCN Red List status' do
      should have_tag('div#iucn_status_container a', /.+/)
    end
    it 'should show overview text' do
      should have_tag('div#text_summary_container', /This is a test Overview, in all its glory/)
    end
    it 'should show info item label when text object title does not exist'
    it 'should show overview text references' do
      should have_tag('div#text_summary_container div.references_container li',
        /A published visible reference for testing./)
    end
    it 'should show doi identifiers for references' do
      body.should have_tag('div#text_summary_container div.references_container li',
        /A published visible reference with a DOI identifier for testing./) do
        with_tag('a', /dx\.doi\.org/)
      end
    end
    it 'should show url identifiers for references' do
      body.should have_tag('div#text_summary_container div.references_container li',
        /A published visible reference with a URL identifier for testing./) do
        with_tag('a', /url\.html/)
      end
    end
    it 'should not show invalid identifiers for references' do
      body.should have_tag('div#text_summary_container div.references_container li',
        /A published visible reference with an invalid identifier for testing./) do
        without_tag('a', /invalid identifier/)
      end
    end
    it 'should not show invisible references' do
      should_not have_tag('div#text_summary_container div.references_container li',
        /A published invisible reference for testing./)
    end
    it 'should not show unpublished references' do
      should_not have_tag('div#text_summary_container div.references_container li',
        /An unpublished visible reference for testing./)
    end
    it 'should show classifications'
    it 'should show collections'
    it 'should show communities'
    it 'should show the activity feed' do
      body.should have_tag('ul.feed') do
        with_tag('.feed_item .body', @testy[:feed_body_1])
        with_tag('.feed_item .body', @testy[:feed_body_2])
        with_tag('.feed_item .body', @testy[:feed_body_3])
      end
    end
    it 'should show curators'
  end

  context 'when taxon does not have any common names' do
    before(:all) { visit("/pages/#{@testy[:taxon_concept_with_no_common_names].id}") }
    subject { body }
    it 'should show common name count as 0 in the content header area' do
      should have_tag('div#content_header_container p', /^(#{@testy[:taxon_concept_with_no_common_names].common_names.count})/)
    end
  end

  # @see 'should render when an object has no agents' in old taxa page spec
  context 'when taxon image does not have an agent' do
    it 'should still render the image'
  end

  context 'when taxon text exists but it does not have any references' do
    it 'should not show references container'
  end

  context 'when taxon does not have any data' do
    before(:all) { visit("/pages/#{@testy[:exemplar].id}") }
    subject { body }
    it 'should show an empty feed' do
      should have_tag('#feed_items_container p.empty', /no activity/i)
    end
  end

  context 'when taxon supercedes another concept' do
    before(:all) { visit("/pages/#{@testy[:superceded_taxon_concept].id}") }
    it 'should use supercedure to find taxon if user visits the other concept' do
      current_path.should == "/pages/#{@testy[:id]}"
    end
    # not sure about this one for overview page, should comments show in recent updates feeds?
    # we can use testy[:superceded_taxon_concept] i.e:
    # comment = Comment.gen(:parent_type => "TaxonConcept", :parent_id => @testy[:superceded_taxon_concept].id, :body => "Comment from superceded taxon concept.")
    it 'should show comments from superceded taxa'
  end

  context 'when taxon is unpublished' do
    before(:all) { visit("/pages/#{@testy[:unpublished_taxon_concept].id}") }
    subject { body }
    it 'should show unauthorised user an error message in the content header' do
      should have_tag('h1', /^Sorry.*?does not exist/)
    end
  end

  context 'when taxon does not exist' do
    before(:all) { visit("/pages/#{TaxonConcept.missing_id}") }
    subject { body }
    it 'should show an error message in the content header' do
      should have_tag('h1', /^Sorry.*?does not exist/)
    end
  end

end