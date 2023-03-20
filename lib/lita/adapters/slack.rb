require 'lita/adapters/slack/chat_service'
require 'lita/adapters/slack/rtm_connection'
require 'net/http'

module Lita
  module Adapters
    # A Slack adapter for Lita.
    # @api private
    class Slack < Adapter
      # Required configuration attributes.
      config :token, type: String, required: true
      config :proxy, type: String
      config :parse, type: [String]
      config :link_names, type: [true, false]
      config :unfurl_links, type: [true, false]
      config :unfurl_media, type: [true, false]
      config :supported_message_subtypes, type: Array, default: []
      config :rtm_connection_verify_peer, type: [true, false], default: true

      # Provides an object for Slack-specific features.
      def chat_service
        ChatService.new(config)
      end

      def mention_format(name)
        "@#{name}"
      end

      # Starts the connection.
      def run
        return if rtm_connection

        @rtm_connection = RTMConnection.build(robot, config)

        unless config.rtm_connection_verify_peer
          Lita.logger.info('SSL connection is going to be verified by Net::HTTP and OpenSSL')
          verify_ssl_connection
        end

        rtm_connection.run
      end

      # Returns UID(s) in an Array or String for:
      # Channels, MPIMs, IMs
      def roster(target)
        api = API.new(config)
        room_roster target.id, api
      end

      def send_messages(target, strings)
        api = API.new(config)
        api.send_messages(channel_for(target), strings)
      end

      def set_topic(target, topic)
        channel = target.room
        Lita.logger.debug("Setting topic for channel #{channel}: #{topic}")
        API.new(config).set_topic(channel, topic)
      end

      def shut_down
        return unless rtm_connection

        rtm_connection.shut_down
        robot.trigger(:disconnected)
      end

      private

      attr_reader :rtm_connection

      def channel_for(target)
        if target.private_message?
          rtm_connection.im_for(target.user.id)
        else
          target.room
        end
      end

      def channel_roster(room_id, api)
        response = api.channels_info room_id
        response['channel']['members']
      end

      # Returns the members of a group, but only can do so if it's a member
      def group_roster(room_id, api)
        response = api.groups_list
        group = response['groups'].select { |hash| hash['id'].eql? room_id }.first
        group.nil? ? [] : group['members']
      end

      # Returns the members of a mpim, but only can do so if it's a member
      def mpim_roster(room_id, api)
        response = api.mpim_list
        mpim = response['groups'].select { |hash| hash['id'].eql? room_id }.first
        mpim.nil? ? [] : mpim['members']
      end

      # Returns the user of an im
      def im_roster(room_id, api)
        response = api.mpim_list
        im = response['ims'].select { |hash| hash['id'].eql? room_id }.first
        im.nil? ? '' : im['user']
      end

      def room_roster(room_id, api)
        case room_id
        when /^C/
          channel_roster room_id, api
        when /^G/
          # Groups & MPIMs have the same room ID pattern, check both if needed
          roster = group_roster room_id, api
          roster.empty? ? mpim_roster(room_id, api) : roster
        when /^D/
          im_roster room_id, api
        end
      end

      def verify_ssl_connection(host = "wss-primary.slack.com", max_retries = 10, wait_time = 5)
        ok = false
        ssl_retry = 0
        while !ok && ssl_retry < max_retries
          begin
            Net::HTTP.start(host, '443', use_ssl: true) { |http| http.peer_cert }
            Lita.logger.info('SSL connection is verified')
            ok = true
          rescue OpenSSL::SSL::SSLError => e
            Lita.logger.info("SSL connection is not verified. Retry #{ssl_retry+1}. Error: #{e.message}. Backtrace: #{e.backtrace}")
            raise if ssl_retry == max_retries
            ok = false
            sleep(wait_time)
          end
        end
      end
    end

    # Register Slack adapter to Lita
    Lita.register_adapter(:slack, Slack)
  end
end
