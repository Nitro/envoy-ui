#!/usr/bin/env crystal

# A webservice that simply makes requests to the Envoy proxy /clusters
# and /stats endpoints and then formats the response as a nice HTML page

require "http/client"
require "http/server"
require "ecr"

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

class EnvoyClient
  def initialize(@host : String, @port : Int32)
    @client = HTTP::Client.new("docker1", 9901)
  end


  def fetch_clusters
    response = @client.get "/clusters"
    puts response.status_code # => 200

    clusters = Hash(String, EnvoyCluster?).new
    return clusters if response.status_code != 200

    parse_clusters_response(response.body, clusters)
  end

  def fetch_server_stats
    response = @client.get "/stats"
    puts response.status_code # => 200

    stats = Hash(String, String).new
    return stats if response.status_code != 200
    parse_stats_response(response.body, stats)
  end

  private def parse_clusters_response(body, clusters)
    body.lines.sort.reduce(clusters) do |memo, line|
      fields = line.split(/::/)
      cluster_name = fields.first
      cluster = (memo[cluster_name] ||= EnvoyCluster.new(cluster_name))

      if fields[0] == "version_info"
        # do nothing
      elsif fields[1] =~ /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:/
        cluster.add_node_value(fields[1], fields[2], fields[3])
      else
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

class ClustersECR
  @clusters : Hash(String, EnvoyCluster?)
  @server_stats : String
  def initialize(@clusters, @server_stats); end
  ECR.def_to_s "clusters.ecr"
end

# Partial that implements the overall server stats
class ServerStatsECR
  @server_stats : Hash(String, String)
  def initialize(@server_stats); end
  ECR.def_to_s "stats.ecr"
end

server = HTTP::Server.new(8080) do |context|
  client = EnvoyClient.new("docker1", 9901)
  context.response.content_type = "text/html"
  clusters = client.fetch_clusters

  stats = client.fetch_server_stats
  server_stats = ServerStatsECR.new(stats).to_s
  context.response.print ClustersECR.new(clusters, server_stats).to_s
end

server.listen
