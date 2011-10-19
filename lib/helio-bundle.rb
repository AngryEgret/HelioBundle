require 'sinatra/base'
require 'rest_client'
require 'crack/json'
require 'json'
require 'yaml'
require 'zip/zip'
require 'aws/s3'

class HelioBundle < Sinatra::Base

  class << self
    attr_accessor :bamboo_url
    attr_accessor :meta_seed
    attr_accessor :version
  
    def configure
      set :lock, false
      set :threaded, true
    end
  end

  get '/Bundle/:farm' do

    metadata = HelioBundle.meta_seed["#{params[:farm]}"]

    metadata[:artifact_list] = Array.new

    metadata[:bamboo_name].each do |plan|
      latest_build = Crack::JSON.parse(RestClient.get "#{HelioBundle.bamboo_url}latest/result/#{plan}.json?buildstate=Successful&max-results=1")["results"]["result"][0]["number"]
    response = Crack::JSON.parse(RestClient.get "#{HelioBundle.bamboo_url}latest/result/#{plan}/#{latest_build}.json?expand=artifacts")

      metadata[:artifact_list].concat(response["artifacts"]['artifact'])
      metadata["#{plan}"] = Hash.new
      metadata["#{plan}"][:vcs_revision] = response["vcsRevisionKey"]
      metadata["#{plan}"][:bamboo_build] = latest_build
    end

    bundle_path = bundle(metadata)

    return bundle_path
  end

  get '/' do
    response = String.new
    response << '<!doctype html>'
    response << '<title>Available Services to Bundle</title><pre>'
    response << HelioBundle.meta_seed.to_yaml
    response << '</pre>'

    return response
  end
end

def bundle(metadata)
  unique = Time.now.to_i
  metadata[:id] = unique

  begin
    Dir::mkdir("/tmp/heliobundle/#{unique}")
  rescue
    puts "the directory already exists"
  end

  begin
    Dir::mkdir("/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}")
  rescue
    puts "the directory already exists"
  end

  zipfile_name = "/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}-#{HelioBundle.version}-ZIP.zip"

  puts zipfile_name
 
  Zip::ZipFile.open(zipfile_name, Zip::ZipFile::CREATE) do |zipfile|

    zipfile.get_output_stream("#{metadata[:helio_name]}/metadata.txt") { |f| f.puts metadata.to_yaml } 

    zipfile.commit
    
    if metadata[:required_artifacts].include?("solr-3.4.0.war")
      http = Net::HTTP.new("artifactory.apollogrp.edu", 443)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      resp = http.get("/artifactory/ext-release-local/solr/solr/3.4.0/solr-3.4.0.war")
      open("/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/solr-3.4.0.war", "w") { |file|
        file.write(resp.body)
      }

      zipfile.add("#{metadata[:helio_name]}/solr-3.4.0.war", "/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/solr-3.4.0.war")
      zipfile.commit
      
      begin
        File.delete("/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/solr-3.4.0.war")
      rescue
        puts "[ERROR]  Delete File:  /tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/solr-3.4.0.war"
        puts "[INFO]   Attempting Delete through shell"
        `rm -rf /tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/solr-3.4.0.war`
      end
    end

    if metadata[:required_artifacts].include?("com.springsource.org.apache.commons.lang-2.4.0.jar")
      http = Net::HTTP.new("artifactory.apollogrp.edu", 443)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      resp = http.get("/artifactory/spring-external-cache/org/apache/commons/com.springsource.org.apache.commons.lang/2.4.0/com.springsource.org.apache.commons.lang-2.4.0.jar")
      open("/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/com.springsource.org.apache.commons.lang-2.4.0.jar", "w") { |file|
        file.write(resp.body)
      }

      zipfile.add("#{metadata[:helio_name]}/com.springsource.org.apache.commons.lang-2.4.0.jar", "/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/com.springsource.org.apache.commons.lang-2.4.0.jar")
      zipfile.commit

      begin
        File.delete("/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/com.springsource.org.apache.commons.lang-2.4.0.jar")
      rescue
        puts "[ERROR]  Delete File:  /tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/com.springsource.org.apache.commons.lang-2.4.0.jar"
        puts "[INFO]   Attempting Delete through shell"      
        `rm -rf /tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/com.springsource.org.apache.commons.lang-2.4.0.jar`
      end
    end
    
    metadata[:artifact_list].each do |artifact|
        url = URI.parse(artifact["link"]["href"])

        file_name = url.path.split('/')[-1]
        file_path = "/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/"

      if metadata[:required_artifacts].include?(file_name)
puts file_name
puts url.path

        http = Net::HTTP.new(url.host, 443)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE

        resp = http.get(url.path)
        open("/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/#{file_name}", "w") { |file|
          file.write(resp.body)
        }

        zipfile.add("#{metadata[:helio_name]}/" + file_name, file_path + file_name)

        if file_name == metadata[:key_file]
          zipfile.add("#{metadata[:helio_name]}/" + metadata[:helio_name] + File.extname(file_name), file_path + file_name)
        end

        zipfile.commit

        begin
          File.delete("/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/#{file_name}")
        rescue
          puts "[ERROR]  Delete File:  /tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/#{file_name}"
          puts "[INFO]   Attempting Delete through shell"
          `rm -rf /tmp/heliobundle/#{unique}/#{metadata[:helio_name]}/#{file_name}`
        end
      end
    end
  end

  if !AWS::S3::S3Object.exists? "/#{metadata[:helio_name]}/#{unique}/#{File.basename(zipfile_name)}", 'apollo_artifacts'

    AWS::S3::S3Object.store(
      "/#{metadata[:helio_name]}/#{unique}/#{File.basename(zipfile_name)}",
      open(zipfile_name),
      'apollo_artifacts'
    )

    AWS::S3::S3Object.copy(
      "/#{metadata[:helio_name]}/#{unique}/#{File.basename(zipfile_name)}",
      "/#{metadata[:helio_name]}/latest/#{File.basename(zipfile_name)}",
      'apollo_artifacts'
    )

    begin
      File.delete(zipfile_name)
    rescue
      puts "[ERROR]  Delete File: #{zipfile_name}"
      puts "[INFO]   Attempting Delete through shell"
      `rm -rf #{zipfile_name}`
    end
  end

  final_url = AWS::S3::S3Object.url_for("/#{metadata[:helio_name]}/#{unique}/#{File.basename(zipfile_name)}",
                   'apollo_artifacts',
                   :expires_in => 60 * 60 * 12)

  begin
    Dir.rmdir("/tmp/heliobundle/#{unique}/#{metadata[:helio_name]}")
    Dir.rmdir("/tmp/heliobundle/#{unique}")
  rescue
    puts "[ERROR]  Delete Directory: /tmp/heliobundle/#{unique}"
    puts "[INFO]   Attempting Delete through shell"
    `rm -rf /tmp/heliobundle/#{unique}`
  end

  return final_url
end

