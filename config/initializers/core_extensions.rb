$CACHE ||= Rails.cache

class String

  # Normalize a string for better matching, e.g. for searches
  def normalize
    # Remember, inline regexes can leak memory.  Storing as variables avoids this.
    @@normalization_regex ||= /[;:,\.\(\)\[\]\!\?\*_\\\/\"\']/
    @@spaces_regex        ||= /\s+/
    @@tag_regex           ||= /<[^>]*>/
    name = self.clone
    return name.downcase.gsub(@@normalization_regex, '').gsub(@@tag_regex, '').gsub(@@spaces_regex, ' ')
    return name.downcase.gsub(@@normalization_regex, '').gsub(@@spaces_regex, ' ')
  end
  
  def strip_italics
    self.gsub(/<\/?i>/i, "")
  end

  def underscore_non_word_chars
    @@non_word_chars_regex ||= /[^A-Za-z0-9\/]/
    @@dup_underscores_regex ||= /__+/
    string = self.clone
    string.gsub(@@non_word_chars_regex, '_').gsub(@@dup_underscores_regex, '_')
  end
end

module ActiveRecord
  class Base
    class << self

      # options is there so that we can pass in the :serialize => true option in the cases where we were using Yaml...
      # I am going to try NOT doing anything with that option right now, to see if it works.  If not, however, I want to at
      # least have it passed in when we needed it, so the code can change later if needed.
      def cached_find(field, value, options = {})
        if v = check_local_cache("#{field}_#{value}".to_sym)
          return v
        end
        response = cached("#{field}/#{value}", options) do
          send("find_by_#{field}", value)
        end
        set_local_cache("#{field}_#{value}".to_sym, response)
        response
      end

      def cached(key, options = {}, &block)
        name = cached_name_for(key)
        if $CACHE # Sometimes during tests, cache has not yet been initialized.
          wrote_cache_key(name)
          $CACHE.fetch(name) do
            yield
          end
        else
          yield
        end
      end

      # Store a list of all of the keys we create for this model (using these cache methods)... speeds up clearing.
      def wrote_cache_key(key)
        name = cached_name_for('cached_names')
        keys = $CACHE.read(name) || []
        return keys if keys.include? key
        keys = keys + [key] # Can't use << or += here because Cache has frozen the array.
        $CACHE.write(name, keys)
      end

      def clear_all_caches
        keys = $CACHE.read(cached_name_for('cached_names')) || []
        keys.each do |key|
          $CACHE.delete(key)
        end
        $CACHE.write(TODO, keys)
      end

      def cached_name_for(key)
        "#{RAILS_ENV}/#{self.table_name}/#{key.underscore_non_word_chars}"[0..249]
      end
      
      def check_local_cache(key)
        initialize_cached_instances
        if local_cache = class_variable_get(:@@cached_instances)
          return local_cache[key]
        end
      end
      def set_local_cache(key, value)
        initialize_cached_instances
        if local_cache = class_variable_get(:@@cached_instances)
          local_cache[key] = value
        end
      end
      def initialize_cached_instances
        unless class_variable_defined?(:@@cached_instances)
          class_variable_set(:@@cached_instances, {})
        end
      end
      def reset_cached_instances
        if class_variable_defined?(:@@cached_instances)
          class_variable_set(:@@cached_instances, {})
        end
      end
    end
  end
end