module Postal
  class Worker

    def initialize(queues)
      @initial_queues = queues
      @active_queues = {}
      @process_name = $0
    end

    def work
      @running_job = false
      Signal.trap("INT")  { @exit = true }
      Signal.trap("TERM") { @exit = true }

      self.class.job_channel.prefetch(1)
      @initial_queues.each { |queue | join_queue(queue) }

      exit_checks = 0
      loop do
        if @exit && @running_job == false
          logger.info "Exiting immediately because no job running"
          exit 0
        elsif @exit
          if exit_checks >= 60
            logger.info "Job did not finish in a timely manner. Exiting"
            exit 0
          end
          if exit_checks == 0
            logger.info "Exit requested but job is running. Waiting for job to finish."
          end
          sleep 60
          exit_checks += 1
        else
          manage_ip_queues
          sleep 1
        end
      end
    end

    private

    def receive_job(delivery_info, properties, body)
      @running_job = true
      begin
        message = JSON.parse(body) rescue nil
        if message && message['class_name']
          start_time = Time.now
          $0 = "#{@process_name} (running #{message['class_name']})"
          Thread.current[:job_id] = message['id']
          logger.info "[#{message['id']}] Started processing \e[34m#{message['class_name']}\e[0m job"
          begin
            klass = message['class_name'].constantize.new(message['id'], message['params'])
            klass.perform
          rescue => e
            Raven.capture_exception(e, :extra => {:job_id => message['id']})
            logger.warn "[#{message['id']}] \e[31m#{e.class}: #{e.message}\e[0m"
            e.backtrace.each do |line|
              logger.warn "[#{message['id']}]    " + line
            end
          ensure
            logger.info "[#{message['id']}] Finished processing \e[34m#{message['class_name']}\e[0m job in #{Time.now - start_time}s"
          end
        end
      ensure
        Thread.current[:job_id] = nil
        $0 = @process_name
        self.class.job_channel.ack(delivery_info.delivery_tag)
        @running_job = false

        if @exit
          logger.info "Exiting because a job has ended."
          exit 0
        end
      end
    end

    def join_queue(queue)
      if @active_queues[queue]
        logger.info "Attempted to join queue #{queue} but already joined."
      else
        consumer = self.class.job_queue(queue).subscribe(:manual_ack => true) do |delivery_info, properties, body|
          receive_job(delivery_info, properties, body)
        end
        @active_queues[queue] = consumer
        logger.info "Joined \e[32m#{queue}\e[0m queue"
      end
    end

    def leave_queue(queue)
      if consumer = @active_queues[queue]
        consumer.cancel
        @active_queues.delete(queue)
        logger.info "Left \e[32m#{queue}\e[0m queue"
      else
        logger.info "Not joined #{queue} so cannot leave"
      end
    end

    def manage_ip_queues
      @ip_queues ||= []
      @ip_to_id_mapping ||= {}
      @unassigned_ips ||= []
      @pairs ||= {}
      # Get all IP addresses on the system
      current_ip_addresses = Socket.ip_address_list.map(&:ip_address)

      # Map them to an actual ID in the database if we can and cache that
      needed_ip_ids = []
      current_ip_addresses.each do |ip|
        need = nil
        if id = @ip_to_id_mapping[ip]
          # We know this IPs ID, we'll just use that.
          need = id
        elsif @unassigned_ips.include?(ip)
          # We know this IP isn't valid. We don't need to do anything
        else
          # We need to look this up
          if ip_address = IPAddress.where("ipv4 = ? OR ipv6 = ?", ip, ip).first
            @pairs[ip_address.ipv4] = ip_address.ipv6
            @ip_to_id_mapping[ip] = ip_address.id
            need = id
          else
            @unassigned_ips << ip
          end
        end

        if need
          pair = @pairs[ip] || @pairs.key(ip)
          if current_ip_addresses.include?(pair)
            needed_ip_ids << id
          else
            logger.info "Host has '#{ip}' but its pair (#{pair}) isn't here. Cannot add now."
          end
        end
      end

      # Make an array of needed queue names
      # Work out what we need to actually do here
      missing_queues = needed_ip_ids - @ip_queues
      unwanted_queues = @ip_queues - needed_ip_ids
      # Leave the queues we don't want any more
      unwanted_queues.each do |id|
        leave_queue("outgoing-#{id}")
        @ip_queues.delete(id)
        ip_addresses_to_clear = []
        @ip_to_id_mapping.each do |_ip, _id|
          if id == _id
            ip_addresses_to_clear << _ip
          end
        end
        ip_addresses_to_clear.each { |ip| @ip_to_id_mapping.delete(ip) }
      end
      # Join any missing queues
      missing_queues.uniq.each do |id|
        join_queue("outgoing-#{id}")
        @ip_queues << id
      end
    end

    def logger
      self.class.logger
    end

    def self.logger
      Postal.logger_for(:worker)
    end

    def self.job_channel
      @channel ||= Postal::RabbitMQ.create_channel
    end

    def self.job_queue(name)
      @job_queues ||= {}
      @job_queues[name] ||= begin
        job_channel.queue("deliver-jobs-#{name}", :durable => true, :arguments => {'x-message-ttl' => 60000})
      end
    end

  end
end
