# encoding: utf-8

require 'logstash/outputs/base'
require 'logstash/namespace'
require 'azure'
require 'tmpdir'
require 'pry'

# An Logstash_Azure_Blob_Output output that does nothing.
class LogStash::Outputs::LogstashAzureBlobOutput < LogStash::Outputs::Base
  require 'logstash/outputs/blob/writable_directory_validator'
  require 'logstash/outputs/blob/path_validator'
  require 'logstash/outputs/blob/size_rotation_policy'
  require 'logstash/outputs/blob/time_rotation_policy'
  require 'logstash/outputs/blob/size_and_time_rotation_policy'
  require 'logstash/outputs/blob/temporary_file'
  require 'logstash/outputs/blob/temporary_file_factory'
  require 'logstash/outputs/blob/uploader'
  require 'logstash/outputs/blob/file_repository'

  PREFIX_KEY_NORMALIZE_CHARACTER = "_"
  PERIODIC_CHECK_INTERVAL_IN_SECONDS = 15
  CRASH_RECOVERY_THREADPOOL = Concurrent::ThreadPoolExecutor.new({
                                                                   :min_threads => 1,
                                                                   :max_threads => 2,
                                                                   :fallback_policy => :caller_runs
                                                                 })

  config_name 'azure'

  # azure contianer
  config :storage_account_name, valdiate: :string, required: false

  # azure key
  config :storage_access_key, valdiate: :string, required: false

  # mamadas
  config :size_file, validate: :number, default: 1024 * 1024 * 5
  config :time_file, validate: :number, default: 15
  config :restore, validate: :boolean, default: true
  config :temporary_directory, validate: :string, default: File.join(Dir.tmpdir, 'logstash')
  config :prefix, validate: :string, default: ''
  config :upload_queue_size, validate: :number, default: 2 * (Concurrent.processor_count * 0.25).ceil
  config :upload_workers_count, validate: :number, default: (Concurrent.processor_count * 0.5).ceil
  config :rotation_strategy, validate: %w[size_and_time size time], default: 'size_and_time'
  config :tags, :validate => :array, :default => []
  config :encoding, :validate => ["none", "gzip"], :default => "none"

  # elimindadas
  # canned acl
  # server side encryption
  # server encryptopn algorithm
  # ssekms
  # storage class
  # signature version
  # tags
  # encoding
  # valdiate credentails on root

  public

  def register
    unless @prefix.empty?
      unless PathValidator.valid?(prefix)
        raise LogStash::ConfigurationError, "Prefix must not contains: #{PathValidator::INVALID_CHARACTERS}"
      end
    end

    unless WritableDirectoryValidator.valid?(@temporary_directory)
      raise LogStash::ConfigurationError, "Logstash must have the permissions to write to the temporary directory: #{@temporary_directory}"
    end

    if @time_file.nil? && @size_file.nil? || @size_file == 0 && @time_file == 0
      raise LogStash::ConfigurationError, 'at least one of time_file or size_file set to a value greater than 0'
    end

    @file_repository = FileRepository.new(@tags, @encoding, @temporary_directory)

    @rotation = rotation_strategy

    executor = Concurrent::ThreadPoolExecutor.new(min_threads: 1,
                                                  max_threads: @upload_workers_count,
                                                  max_queue: @upload_queue_size,
                                                  fallback_policy: :caller_runs)

    @uploader = Uploader.new(blob_contianer_resource, @logger, executor)

    restore_from_crash if @restore
    start_periodic_check if @rotation.needs_periodic?
  end # def register

  def multi_receive_encoded(events_and_encoded)
    prefix_written_to = Set.new

    events_and_encoded.each do |event, encoded|
      prefix_key = normalize_key(event.sprintf(@prefix))
      prefix_written_to << prefix_key

      begin
        @file_repository.get_file(prefix_key) { |file| file.write(encoded) }
        # The output should stop accepting new events coming in, since it cannot do anything with them anymore.
        # Log the error and rethrow it.
      rescue Errno::ENOSPC => e
        @logger.error('S3: No space left in temporary directory', temporary_directory: @temporary_directory)
        raise e
      end
    end

    # Groups IO calls to optimize fstat checks
    rotate_if_needed(prefix_written_to)
  end

  def close
    stop_periodic_check if @rotation.needs_periodic?

    @logger.debug('Uploading current workspace')

    # The plugin has stopped receiving new events, but we still have
    # data on disk, lets make sure it get to S3.
    # If Logstash get interrupted, the `restore_from_crash` (when set to true) method will pickup
    # the content in the temporary directly and upload it.
    # This will block the shutdown until all upload are done or the use force quit.
    @file_repository.each_files do |file|
      upload_file(file)
    end

    @file_repository.shutdown

    @uploader.stop # wait until all the current upload are complete
    @crash_uploader.stop if @restore # we might have still work to do for recovery so wait until we are done
  end

  def normalize_key(prefix_key)
    prefix_key.gsub(PathValidator.matches_re, PREFIX_KEY_NORMALIZE_CHARACTER)
  end

  def upload_options
    {
    }
  end

  def start_periodic_check
    @logger.debug("Start periodic rotation check")

    @periodic_check = Concurrent::TimerTask.new(:execution_interval => PERIODIC_CHECK_INTERVAL_IN_SECONDS) do
      @logger.debug("Periodic check for stale files")

      rotate_if_needed(@file_repository.keys)
    end

    @periodic_check.execute
  end

  def stop_periodic_check
    @periodic_check.shutdown
  end

  def blob_contianer_resource
    azure_blob_service = Azure::Blob::BlobService.new
    list = azure_blob_service.list_containers()
    list.each do |item|
      @container = item if item.name == "jaime-test-1"
    end
    azure_blob_service.create_container("jaime-test-1") unless @container
  end

  def rotate_if_needed(prefixes)
    prefixes.each do |prefix|
      # Each file access is thread safe,
      # until the rotation is done then only
      # one thread has access to the resource.
      @file_repository.get_factory(prefix) do |factory|
        temp_file = factory.current

        if @rotation.rotate?(temp_file)
          @logger.debug("Rotate file",
                        :strategy => @rotation.class.name,
                        :key => temp_file.key,
                        :path => temp_file.path)

          upload_file(temp_file)
          factory.rotate!
        end
      end
    end
  end

  def upload_file(temp_file)
    @logger.debug("Queue for upload", :path => temp_file.path)

    # if the queue is full the calling thread will be used to upload
    temp_file.close # make sure the content is on disk
    if temp_file.size > 0
      @uploader.upload_async(temp_file,
                             :on_complete => method(:clean_temporary_file),
                             :upload_options => upload_options )
    end
  end


  def rotation_strategy
    case @rotation_strategy
    when "size"
      SizeRotationPolicy.new(size_file)
    when "time"
      TimeRotationPolicy.new(time_file)
    when "size_and_time"
      SizeAndTimeRotationPolicy.new(size_file, time_file)
    end
  end

  def clean_temporary_file(file)
    @logger.debug("Removing temporary file", :file => file.path)
    file.delete!
  end

  def restore_from_crash
    @crash_uploader = Uploader.new(blob_contianer_resource, @logger, CRASH_RECOVERY_THREADPOOL)

    temp_folder_path = Pathname.new(@temporary_directory)
    Dir.glob(::File.join(@temporary_directory, "**/*"))
      .select { |file| ::File.file?(file) }
      .each do |file|
      temp_file = TemporaryFile.create_from_existing_file(file, temp_folder_path)
      @logger.debug("Recovering from crash and uploading", :file => temp_file.path)
      @crash_uploader.upload_async(temp_file, :on_complete => method(:clean_temporary_file), :upload_options => upload_options)
    end
  end


  public

  def receive(event)
    azure_login
    azure_blob_service = Azure::Blob::BlobService.new
    containers = azure_blob_service.list_containers
    blob = azure_blob_service.create_block_blob(containers[0].name, event.timestamp.to_s, event.to_json)
  end # def event

  def azure_login
    Azure.config.storage_account_name ||= ENV['AZURE_STORAGE_ACCOUNT']
    Azure.config.storage_access_key ||= ENV['AZURE_STORAGE_ACCESS_KEY']
  end # def azure_login
end # class LogStash::Outputs::LogstashAzureBlobOutput
