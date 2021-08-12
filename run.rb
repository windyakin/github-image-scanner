require "graphql/client"
require "graphql/client/http"
require 'docker'
require 'octokit'
require 'yaml'
require 'logger'
require 'date'

logger = Logger.new(STDOUT)
config = YAML.load_file("./config.yml")
Octokit.configure do |c|
  c.api_endpoint = ENV['GITHUB_API']
end

module SWAPI
  HTTP = GraphQL::Client::HTTP.new(File.join(ENV['GITHUB_API'].gsub(/v3\/?/, ''), 'graphql')) do
    def headers(context)
      h = {
        "User-Agent": "github-image-scaner"
      }
      h["Authorization"] = "token #{ENV['GITHUB_TOKEN']}" if ENV['GITHUB_TOKEN']
      h
    end
  end

  Schema = GraphQL::Client.load_schema(HTTP)
  Client = GraphQL::Client.new(schema: Schema, execute: HTTP)
end

trivy = Docker::Image.create('fromImage' => "aquasec/trivy")
Docker.authenticate!('username' => ENV['GITHUB_USER'], 'password' => ENV['GITHUB_TOKEN'], 'serveraddress' => "https://#{config["registory_domain"]}") if config["registory_domain"]

client = Octokit::Client.new(
  access_token: ENV['GITHUB_TOKEN'],
  auto_paginate: true,
  per_page: 300
)

config["orgs"].each do |o|
  repos = begin
            client.organization(o)
            client.organization_repositories(o)
          rescue
            client.repositories(o)
          end
  repos.map{|m| m[:name] }.each do |r|
    logger.info "start #{o}/#{r}"
    Query = SWAPI::Client.parse <<~GRAPHQL
    query {
              repository(owner: "#{o}", name: "#{r}") {
                  packages(first:100){
                    nodes {
                        id
                        name
                        packageType
                        versions(first:100) {
                            nodes {
                                id
                                version
                                files(first: 10) {
                                    nodes {
                                        name
                                        updatedAt
                                    }
                                }
                            }
                        }
                    }
                  }
              }
          }
    GRAPHQL

    response = SWAPI::Client.query(Query)
    result = {}
    if data = response.data
      begin
        data.to_h["repository"]["packages"]["nodes"].select {|n| n["packageType"] == "DOCKER" }.each do |i|
          image_name = "#{config["registory_domain"]}/#{o}/#{r}/#{i["name"]}:#{i["versions"]["nodes"].first["version"]}"

          logger.info "check image name #{image_name}"

          next if config["ignore_images"].find {|i| image_name =~ /#{i}/ }

          image = Docker::Image.create('fromImage' => image_name)
          vols = []
          vols << "#{Dir.pwd}/cache:/root/.cache"
          vols << "/var/run/docker.sock:/var/run/docker.sock"
          container = ::Docker::Container.create({
            'Image' => trivy.id,
            'HostConfig' => {
              'Binds' => vols,
            },
            'Cmd' => [
              "--ignore-unfixed",
              "-s",
              "HIGH,CRITICAL",
              "--format",
              "template",
              "--template",
             "@contrib/html.tpl",
               "--exit-code",
              "1",
              image_name
            ]
          })

          container.tap(&:start).attach do |stream, chunk|
            logger.debug "#{stream} #{chunk}"
            result[image_name] ||= {}
            result[image_name][stream] ||= []
            result[image_name][stream] << chunk
          end

          result[image_name][:status_code] = container.wait["StatusCode"]
          container.remove(:force => true)
          logger.info "check result #{o}/#{r} exit:#{result[image_name][:status_code]}"
        end

        next if result.empty? || result.all? {|_,v| v[:status_code] == 0 }

        t = ["# These image has vulnability."]
        result.each do |k,v|
          t << v[:stdout]
        end

        issue_txt = t.join("\n")
          .gsub(/<head>.+?<\/head>/m, '')
          .gsub(/<\/?body>/m, '')
          .gsub(/<\/?html>/m, '')
          .gsub(/^\d{4}-\d{2}-\d{2}T\d{2}.+$/, '')
          .gsub(/<!DOCTYPE html>/, '')
          .gsub(/^\s*$/, '')
          .gsub(/^\n/, '')
          .gsub(/^    /m, '')

        logger.info "create issue #{o}/#{r}"
        client.create_issue("#{o}/#{r}", "#{Date.today.strftime("%Y/%m/%d")} Found vulnerabilities in docker image", issue_txt)
      rescue => e
        logger.error "#{o}/#{r} happend error #{e}"
      end
    elsif response.errors.any?
       logger.error response.errors.messages["data"]
    end
  end
end
