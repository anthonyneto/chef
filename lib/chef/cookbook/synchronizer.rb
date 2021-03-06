require 'chef/client'
require 'chef/util/threaded_job_queue'
require 'chef/server_api'
require 'singleton'

class Chef

  # Keep track of the filenames that we use in both eager cookbook
  # downloading (during sync_cookbooks) and lazy (during the run
  # itself, through FileVendor). After the run is over, clean up the
  # cache.
  class CookbookCacheCleaner

    attr_accessor :skip_removal

    # Setup a notification to clear the valid_cache_entries when a Chef client
    # run starts
    Chef::Client.when_run_starts do |run_status|
      instance.reset!
    end

    # Register a notification to cleanup unused files from cookbooks
    Chef::Client.when_run_completes_successfully do |run_status|
      instance.cleanup_file_cache
    end

    include Singleton

    def initialize
      reset!
    end

    def reset!
      @valid_cache_entries = {}
    end

    def mark_file_as_valid(cache_path)
      @valid_cache_entries[cache_path] = true
    end

    def cache
      Chef::FileCache
    end

    def cleanup_file_cache
      unless Chef::Config[:solo] || skip_removal
        # Delete each file in the cache that we didn't encounter in the
        # manifest.
        cache.find(File.join(%w{cookbooks ** {*,.*}})).each do |cache_filename|
          unless @valid_cache_entries[cache_filename]
            Chef::Log.info("Removing #{cache_filename} from the cache; it is no longer needed by chef-client.")
            cache.delete(cache_filename)
          end
        end
      else
        Chef::Log.info("Skipping removal of unused files from the cache")
      end
    end

  end

  # Synchronizes the locally cached copies of cookbooks with the files on the
  # server.
  class CookbookSynchronizer
    CookbookFile = Struct.new(:cookbook, :segment, :manifest_record)

    attr_accessor :remove_obsoleted_files

    def initialize(cookbooks_by_name, events)
      @eager_segments = Chef::CookbookVersion::COOKBOOK_SEGMENTS.dup
      unless Chef::Config[:no_lazy_load]
        @eager_segments.delete(:files)
        @eager_segments.delete(:templates)
      end
      @eager_segments.freeze

      @cookbooks_by_name, @events = cookbooks_by_name, events

      @cookbook_full_file_paths = {}
      @remove_obsoleted_files = true
    end

    def cache
      Chef::FileCache
    end

    def cookbook_names
      @cookbooks_by_name.keys
    end

    def cookbooks
      @cookbooks_by_name.values
    end

    def cookbook_count
      @cookbooks_by_name.size
    end

    def have_cookbook?(cookbook_name)
      @cookbooks_by_name.key?(cookbook_name)
    end

    def cookbook_segment(cookbook_name, segment)
      @cookbooks_by_name[cookbook_name].manifest[segment]
    end

    def files
      @files ||= cookbooks.inject([]) do |memo, cookbook|
        @eager_segments.each do |segment|
          cookbook.manifest[segment].each do |manifest_record|
            memo << CookbookFile.new(cookbook, segment, manifest_record)
          end
        end
        memo
      end
    end

    def files_by_cookbook
      files.group_by { |file| file.cookbook }
    end

    def files_remaining_by_cookbook
      @files_remaining_by_cookbook ||= begin
        files_by_cookbook.inject({}) do |memo, (cookbook, files)|
          memo[cookbook] = files.size
          memo
        end
      end
    end

    def mark_file_synced(file)
      files_remaining_by_cookbook[file.cookbook] -= 1

      if files_remaining_by_cookbook[file.cookbook] == 0
        @events.synchronized_cookbook(file.cookbook.name, file.cookbook)
      end
    end

    # Synchronizes all the cookbooks from the chef-server.
    #)
    # === Returns
    # true:: Always returns true
    def sync_cookbooks
      Chef::Log.info("Loading cookbooks [#{cookbooks.map {|ckbk| ckbk.name + '@' + ckbk.version}.join(', ')}]")
      Chef::Log.debug("Cookbooks detail: #{cookbooks.inspect}")

      clear_obsoleted_cookbooks

      queue = Chef::Util::ThreadedJobQueue.new

      files.each do |file|
        queue << lambda do |lock|
          full_file_path = sync_file(file)

          lock.synchronize {
            # Save the full_path of the downloaded file to be restored in the manifest later
            save_full_file_path(file, full_file_path)
            mark_file_synced(file)
          }
        end
      end

      @events.cookbook_sync_start(cookbook_count)
      queue.process(Chef::Config[:cookbook_sync_threads])
      # Update the full file paths in the manifest
      update_cookbook_filenames()

    rescue Exception => e
      @events.cookbook_sync_failed(cookbooks, e)
      raise
    else
      @events.cookbook_sync_complete
      true
    end

    # Saves the full_path to the file of the cookbook to be updated
    # in the manifest later
    def save_full_file_path(file, full_path)
      @cookbook_full_file_paths[file.cookbook] ||= { }
      @cookbook_full_file_paths[file.cookbook][file.segment] ||= [ ]
      @cookbook_full_file_paths[file.cookbook][file.segment] << full_path
    end

    # remove cookbooks that are not referenced in the expanded run_list at all
    # (if we have an override run_list we may not want to do this)
    def remove_old_cookbooks
      cache.find(File.join(%w{cookbooks ** {*,.*}})).each do |cache_file|
        cache_file =~ /^cookbooks\/([^\/]+)\//
        unless have_cookbook?($1)
          Chef::Log.info("Removing #{cache_file} from the cache; its cookbook is no longer needed on this client.")
          cache.delete(cache_file)
          @events.removed_cookbook_file(cache_file)
        end
      end
    end

    # remove deleted files in cookbooks that are being used on the node
    def remove_deleted_files
      cache.find(File.join(%w{cookbooks ** {*,.*}})).each do |cache_file|
        md = cache_file.match(/^cookbooks\/([^\/]+)\/([^\/]+)\/(.*)/)
        next unless md
        ( cookbook_name, segment, file ) = md[1..3]
        if have_cookbook?(cookbook_name)
          manifest_segment = cookbook_segment(cookbook_name, segment)
          if manifest_segment.select { |manifest_record| manifest_record["path"] == "#{segment}/#{file}" }.empty?
            Chef::Log.info("Removing #{cache_file} from the cache; its is no longer in the cookbook manifest.")
            cache.delete(cache_file)
            @events.removed_cookbook_file(cache_file)
          end
        end
      end
    end

    # Iterates over cached cookbooks' files, removing files belonging to
    # cookbooks that don't appear in +cookbook_hash+
    def clear_obsoleted_cookbooks
      @events.cookbook_clean_start

      if remove_obsoleted_files
        remove_old_cookbooks
      else
        Chef::Log.info("Skipping removal of obsoleted cookbooks from the cache")
        CookbookCacheCleaner.instance.skip_removal = true
      end

      remove_deleted_files

      @events.cookbook_clean_complete
    end

    def update_cookbook_filenames
      @cookbook_full_file_paths.each do |cookbook, file_segments|
        file_segments.each do |segment, full_paths|
          cookbook.replace_segment_filenames(segment, full_paths)
        end
      end
    end

    # Sync an individual file if needed. If there is an up to date copy
    # locally, nothing is done. Updates +file+'s manifest with the full path to
    # the cached file.
    #
    # === Arguments
    # file<CookbookFile>
    # === Returns
    # Full path to the cached file as a String
    def sync_file(file)
      cache_filename = File.join("cookbooks", file.cookbook.name, file.manifest_record['path'])
      mark_cached_file_valid(cache_filename)

      # If the checksums are different between on-disk (current) and on-server
      # (remote, per manifest), do the update. This will also execute if there
      # is no current checksum.
      if !cached_copy_up_to_date?(cache_filename, file.manifest_record['checksum'])
        download_file(file.manifest_record['url'], cache_filename)
        @events.updated_cookbook_file(file.cookbook.name, cache_filename)
      else
        Chef::Log.debug("Not storing #{cache_filename}, as the cache is up to date.")
      end

      # Load the file in the cache and return the full file path to the loaded file
      cache.load(cache_filename, false)
    end

    def cached_copy_up_to_date?(local_path, expected_checksum)
      if cache.has_key?(local_path)
        current_checksum = CookbookVersion.checksum_cookbook_file(cache.load(local_path, false))
        expected_checksum == current_checksum
      else
        false
      end
    end

    # Unconditionally download the file from the given URL. File will be
    # downloaded to the path +destination+ which is relative to the Chef file
    # cache root.
    def download_file(url, destination)
      raw_file = server_api.streaming_request(url)

      Chef::Log.info("Storing updated #{destination} in the cache.")
      cache.move_to(raw_file.path, destination)
    end

    # Marks the given file as valid (non-stale).
    def mark_cached_file_valid(cache_filename)
      CookbookCacheCleaner.instance.mark_file_as_valid(cache_filename)
    end

    def server_api
      Chef::ServerAPI.new(Chef::Config[:chef_server_url])
    end

  end
end
