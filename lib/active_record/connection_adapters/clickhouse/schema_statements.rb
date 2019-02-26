# frozen_string_literal: true

require 'faraday'

module ActiveRecord
  module ConnectionAdapters
    module Clickhouse
      module SchemaStatements
        def execute(sql, name = nil, body = nil, query_format = 'JSONCompact')
          do_execute(sql, name, body, query_format)
        end

        def exec_insert(sql, name, _binds, _pk = nil, _sequence_name = nil)
          new_sql = sql.dup.sub(/ (DEFAULT )?VALUES/, " VALUES")
          do_execute(new_sql, name, nil, nil)
          true
        end

        def exec_query(sql, name = nil, binds = [], prepare: false)
          result = do_execute(sql, name)
          ActiveRecord::Result.new(result['meta'].map { |m| m['name'] }, result['data'])
        end

        def exec_update(_sql, _name = nil, _binds = [])
          raise ActiveRecord::ActiveRecordError, 'Clickhouse update is not supported'
        end

        def exec_delete(_sql, _name = nil, _binds = [])
          raise ActiveRecord::ActiveRecordError, 'Clickhouse delete is not supported'
        end

        def tables(name = nil)
          result = do_execute('SHOW TABLES', name)
          return [] if result.nil?
          result['data'].flatten
        end

        # Not indexes on clickhouse
        def indexes(table_name, name = nil)
          []
        end

        def data_sources
          tables
        end


        private


        def path(query)
          params = @config.select{|k, _v| k == :database}
          params[:query] = query
          params[:output_format_write_statistics] = 1

          URI.encode_www_form(params)
        end

        def apply_format(sql, query_format)
          query_format ? "#{sql} FORMAT #{query_format}" : sql
        end

        def do_execute(sql, name = nil, body = nil, query_format = 'JSONCompact')
          log(sql, "#{adapter_name} #{name}") do
            formatted_sql = apply_format(sql, query_format) if query_format
            response = @connection.post("/?#{path(formatted_sql)}", body)

            process_response(response, query_format)
          end
        end

        def process_response(response, format)
          unless response.status == 200
            raise ActiveRecord::ActiveRecordError, "Response code: #{response.status}:\n#{response.body}"
          end

          case format
          when 'JSON', 'JSONCompact'
            JSON.parse(response.body) if response.body.strip[0] == "{"
          else
            response.body
          end
        end

        def log_with_debug(sql, name = nil)
          return yield unless self.pool.spec.config[:debug]
          log(sql, "#{name} (system)") { yield }
        end

        def schema_creation
          Clickhouse::SchemaCreation.new(self)
        end

        def create_table_definition(*args)
          Clickhouse::TableDefinition.new(*args)
        end

        def new_column_from_field(table_name, field)
          sql_type = field[1]
          type_metadata = fetch_type_metadata(sql_type)
          ClickhouseColumn.new(field[0], field[3].present? ? field[3] : nil, type_metadata, field[1].include?('Nullable'), table_name, nil)
        end

        protected

        def table_structure(table_name)
          result = do_execute("DESCRIBE TABLE #{table_name}", table_name)
          data = result['data']

          return data unless data.empty?

          raise ActiveRecord::StatementInvalid,
            "Could not find table '#{table_name}'"
        end
        alias column_definitions table_structure
      end
    end
  end
end
