#!/usr/bin/env crystal

# A webservice that simply makes requests to the Envoy proxy /clusters
# and /stats endpoints and then formats the response as a nice HTML page

require "http/client"
require "http/server"
require "ecr"
require "option_parser"

# An EnvoyCluster represents all the data and stats about a single
# cluster, including all the services and some settings.
class EnvoyCluster
  @name : String?
  @version : String?
  @long_settings : Hash(String, Hash(String, String))
  @short_settings : Hash(String, String)
  @nodes : Hash(String, Hash(String, String))

  property :name, :version, :short_settings, :long_settings, :nodes

  def initialize(@name : String)
    @long_settings = Hash(String, Hash(String, String)).new
    @short_settings = Hash(String, String).new
    @nodes = Hash(String, Hash(String, String)).new
  end

  def add_setting(name : String, sub_name : String, value : String)
    if sub_name != ""
      @long_settings[name] = Hash(String, String).new if !@long_settings[name]?
      @long_settings[name][sub_name] = value
      return
    end

    @short_settings[name] = value
  end

  def add_node_value(name, key, value)
    @nodes[name] ||= Hash(String, String).new
    return if @nodes[name].nil?
    @nodes[name][key] = value
  end
end

# An EnvoyClient connects to the Envoy proxy /clusters and /stats endpoints
# and returns some data structures containing the parsed data.
class EnvoyClient
  def initialize(@host : String, @port : Int32)
    @client = HTTP::Client.new(@host, @port)
  end

  def fetch_clusters
    clusters = Hash(String, EnvoyCluster?).new
    response = begin
      @client.get "/clusters"
    rescue ex : Errno
      return {err: ex.to_s, clusters: clusters}
    end

    if response.status_code != 200
      return {
        err: "Bad status code from server: #{response.status_code}",
        clusters: clusters
      }
    end

    {
      err: nil,
      clusters: parse_clusters_response(response.body, clusters)
    }
  end

  def fetch_server_stats
    stats = Hash(String, String).new
    response = begin
      @client.get "/stats"
    rescue ex : Errno
      return {err: ex.to_s, stats: stats}
    end
    if response.status_code != 200
      return {
        err: "Bad status code from server: #{response.status_code}",
        stats: stats
      }
    end

    {
      err: nil,
      stats: parse_stats_response(response.body, stats)
    }
  end

  private def parse_clusters_response(body, clusters)
    body.lines.sort.reduce(clusters) do |memo, line|
      fields = line.split(/::/)
      if fields[0] =~ /version_info/
        # do nothing
      elsif fields[1] =~ /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:/
        cluster_name = fields.first
        cluster = (memo[cluster_name] ||= EnvoyCluster.new(cluster_name))
        cluster.add_node_value(fields[1], fields[2], fields[3])
      else
        cluster_name = fields.first
        cluster = (memo[cluster_name] ||= EnvoyCluster.new(cluster_name))

        case fields.size
        when 4
          cluster.add_setting(fields[1], fields[2], fields[3])
        when 3
          cluster.add_setting(fields[1], "", fields[2])
        end
      end

      memo
    end
  end

  private def parse_stats_response(body, stats : Hash(String, String))
    body.lines.select { |l| l =~ /^server/ }.reduce(stats) do |memo, line|
      fields = line.split(/[.:]/)
      memo[fields[1]] = fields[2]
      memo
    end
  end
end

# Web Views ----------------------------------------------
class ClustersECR
  @clusters : Hash(String, EnvoyCluster?)
  @server_stats : String
  @errors : Array(String)

  def initialize(@clusters, @server_stats, @errors); end
  ECR.def_to_s "clusters.ecr"
end

# Partial that implements the overall server stats
class ServerStatsECR
  @server_stats : Hash(String, String)
  def initialize(@server_stats); end
  ECR.def_to_s "stats.ecr"
end
# --------------------------------------------------------



# Main ---------------------------------------------------
host = "127.0.0.1"
port = 9901
listen_port = 8080

OptionParser.parse! do |parser|
  parser.banner = "Usage: envoy-ui [arguments]"
  parser.on("-h HOSTNAME", "--host=HOSTNAME", "Envoy proxy hostname") { |h| host = h.to_s }
  parser.on("-p PORT", "--port=PORT", "Envoy proxy port")             { |p| port = p.to_i }
  parser.on("-l PORT", "--listen-port=PORT", "Port to listen on")     { |l| listen_port = l.to_i }
  parser.on("--help", "Show this help")                               { puts parser; exit }
end

puts "Envoy UI starting ------------------------"
puts " * Envoy address: #{host}:#{port}"
puts " * Listening on:  0.0.0.0:#{listen_port}"
puts "------------------------------------------"

server = HTTP::Server.new("0.0.0.0", listen_port, [
  HTTP::ErrorHandler.new,
  HTTP::LogHandler.new
]) do |context|
  errors = [] of String
  client = EnvoyClient.new(host, port)
  context.response.content_type = "text/html"

  clusters_result = client.fetch_clusters
  errors << "clusters: #{clusters_result[:err].as(String)}" if clusters_result[:err]

  stats_result = client.fetch_server_stats
  errors << "stats: #{stats_result[:err].as(String)}" if stats_result[:err]

  server_stats = ServerStatsECR.new(
    stats_result[:stats]
  ).to_s
  context.response.print ClustersECR.new(
    clusters_result[:clusters], server_stats, errors
  ).to_s
end

server.listen
