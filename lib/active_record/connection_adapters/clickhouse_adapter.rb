# frozen_string_literal: true

require 'clickhouse-activerecord/arel/visitors/to_sql'
require 'active_record/connection_adapters/abstract_adapter'
require 'active_record/connection_adapters/clickhouse/oid/date'
require 'active_record/connection_adapters/clickhouse/oid/date_time'
require 'active_record/connection_adapters/clickhouse/oid/big_integer'
require 'active_record/connection_adapters/clickhouse/schema_definitions'
require 'active_record/connection_adapters/clickhouse/schema_creation'
require 'active_record/connection_adapters/clickhouse/schema_statements'

module ActiveRecord
  class Base
    class << self
      # Establishes a connection to the database that's used by all Active Record objects
      def clickhouse_connection(config)
        config = config.symbolize_keys
        scheme = config[:scheme] || 'http'
        host = config[:host]
        port = config[:port] || 8123

        if config.key?(:database)
          database = config[:database]
        else
          raise ArgumentError, 'No database specified. Missing argument: database.'
        end

        ConnectionAdapters::ClickhouseAdapter.new(nil, logger, [scheme, host, port], { user: config[:username], password: config[:password], database: database }.compact)
      end
    end
  end

  module ModelSchema
     module ClassMethods
      def is_view
        @is_view || false
      end
       # @param [Boolean] value
      def is_view=(value)
        @is_view = value
      end
    end
   end

  module ConnectionAdapters
    class ClickhouseColumn < Column

      private

      # Extracts the value from a PostgreSQL column default definition.
      def extract_value_from_default(default)
        case default
          # Quoted types
        when /\A[\(B]?'(.*)'.*::"?([\w. ]+)"?(?:\[\])?\z/m
          # The default 'now'::date is CURRENT_DATE
          if $1 == "now".freeze && $2 == "date".freeze
            nil
          else
            $1.gsub("''".freeze, "'".freeze)
          end
          # Boolean types
        when "true".freeze, "false".freeze
          default
          # Numeric types
        when /\A\(?(-?\d+(\.\d*)?)\)?(::bigint)?\z/
          $1
          # Object identifier types
        when /\A-?\d+\z/
          $1
        else
          # Anything else is blank, some user type, or some function
          # and we can't know the value of that, so return nil.
          nil
        end
      end

      def extract_default_function(default_value, default) # :nodoc:
        default if has_default_function?(default_value, default)
      end

      def has_default_function?(default_value, default) # :nodoc:
        !default_value && (%r{\w+\(.*\)} === default)
      end

    end

    class ClickhouseAdapter < AbstractAdapter
      ADAPTER_NAME = 'Clickhouse'.freeze

      NATIVE_DATABASE_TYPES = {
        string: { name: 'String' },
        integer: { name: 'UInt32' },
        big_integer: { name: 'UInt64' },
        float: { name: 'Float32' },
        decimal: { name: 'Decimal' },
        datetime: { name: 'DateTime' },
        date: { name: 'Date' },
        boolean: { name: 'UInt8' }
      }.freeze

      include Clickhouse::SchemaStatements

      # Initializes and connects a Clickhouse adapter.
      def initialize(connection, logger, connection_parameters, config)
        super(connection, logger)
        @connection_parameters = connection_parameters
        @config = config

        @prepared_statements = false

        connect
      end

      def arel_visitor # :nodoc:
        ClickhouseActiverecord::Arel::Visitors::ToSql.new(self)
      end

      def native_database_types #:nodoc:
        NATIVE_DATABASE_TYPES
      end

      def valid_type?(type)
        !native_database_types[type].nil?
      end

      def extract_limit(sql_type) # :nodoc:
        case sql_type
          when 'Nullable(String)'
            255
          when /Nullable\(U?Int(8|16)\)/
            4
          when /Nullable\(U?Int(32|64)\)/
            8
          else
            super
        end
      end

      def initialize_type_map(m) # :nodoc:
        super
        register_class_with_limit m, 'String', Type::String
        register_class_with_limit m, 'Nullable(String)', Type::String
        register_class_with_limit m, 'Uint8', Type::UnsignedInteger
        register_class_with_limit m, 'Date',  Clickhouse::OID::Date
        register_class_with_limit m, 'DateTime',  Clickhouse::OID::DateTime
        m.alias_type 'UInt16', 'uint4'
        m.alias_type 'UInt32', 'uint8'
        m.register_type 'UInt64', Clickhouse::OID::BigInteger.new
        m.alias_type 'Int8', 'int4'
        m.alias_type 'Int16', 'int4'
        m.alias_type 'Int32', 'int8'
        m.alias_type 'Int64', 'UInt64'
      end

      # Executes insert +sql+ statement in the context of this connection using
      # +binds+ as the bind substitutes. +name+ is logged along with
      # the executed +sql+ statement.

      # SCHEMA STATEMENTS ========================================

      def primary_key(table_name) #:nodoc:
        pk = table_structure(table_name).first
        return 'id' if pk.present? && pk[0] == 'id'
        false
      end

      protected

      def last_inserted_id(result)
        result
      end

      private

      def connect
        scheme, host, port = @connection_parameters
        @connection = Faraday.new("#{scheme}://#{host}:#{port}")
        @connection.basic_auth(@config[:user] || "default", @config[:password]) if @config[:user] || @config[:password]
        ping!
      end

      def ping!
        status = @connection.get("/").status

        if status != 200
          raise "Unexpected response status: #{status}"
        end

        true
      end
    end
  end
end
