module Lingohub
  module Models
    require 'lingohub/models/resource'

    class Project
      def self.lazy_attr_accessor(*params)
        params.each do |sym|
          define_method(sym) do
            unless defined? @fetched
              fetch
            end
            self.instance_variable_get("@#{sym}")
          end
          define_method("#{sym}=") do |value|
            self.instance_variable_set("@#{sym}", value)
          end
        end
      end

      lazy_attr_accessor(:title, :link, :weburl, :resources_url, :translations_url,
                        :exports_url, :export_id, :export_download_url,
                        :search_url, :owner, :description, :project_locales)

      def initialize(client, link)
        @client = client
        @link = link
      end

      def resources
        unless defined? @resources
          @resources = { }
          response = @client.get(self.resources_url)
          resource_hash = JSON.parse(response)
          members = resource_hash["members"]
          members.each do |member|
            @resources[member["name"]] = Lingohub::Models::Resource.new(@client, member["project_locale"], member["links"][0]["href"])
          end
        end
        @resources
      end

      def initiate_export
        puts "Initiating a new export"

        response = @client.post(self.exports_url, "", {'content-type'=> 'application/json', 'accept'=> '*'})
        export_id = JSON.parse(response)["id"]

        puts "\tThe export id is: #{export_id}"
        init_attributes :export_id => export_id
      end

      def await_export_readiness
        puts "Waiting for the export to be complete"

        loop.with_index { |_, counter|
          export_info = get_export_info
          export_status = export_info["status"]
          puts "\t#{counter + 1}. Export Status: #{export_status}"

          case export_status
          when "PROCESSING"
            sleep 5
          when "SUCCESS"
            init_attributes :export_download_url => export_info["downloadUrl"]
            break
          else
            raise "The export failed with the following error: #{export_info['errorDetails']}"
          end
        }
      end

      def get_export_info
        response = @client.get("#{self.exports_url}/#{self.export_id}", {'content-type'=> 'application/json', 'accept'=> '*'})
        parsed_response = JSON.parse(response)

        parsed_response
      end

      def download_and_extract_export
        puts "Downloading and exporting the locales"

        puts "\tDownloading the export file"
        export_file = @client.get_export_file(self.export_download_url).body

        puts "\tSaving the export file temporarily on disk"
        File.open("temp.zip", "wb") { |file| file.write export_file }

        puts "\tUnzipping the export file"
        system("unzip -d temp temp.zip > /dev/null")

        puts "\tMoving all new locales to their respective folders"
        system([
          "for file in ./temp/*; do",
          "locale=$(echo $file | awk -F'.' '{print $3}');",
          'destination="app/locales/${locale}";',
          "[ -d $destination ] && mv $file $destination;",
          "done",
        ].join(' '))

        puts "\tCleaning all temporary and irrelevant files"
        system("rm temp.zip")
        system("rm -fr ./temp")
        system("git clean -qf")
      end

      def download_resource(directory, filename, locale_as_filter = nil)
        raise "Project does not contain that file." unless self.resources.has_key?(filename)
        resource = self.resources[filename]

        if locale_as_filter.nil? || resource_has_locale(resource, locale_as_filter)
          save_to_file(File.join(directory, filename), resource.content)
          true
        else
          false
        end
      end

      def upload_resource(path, locale, strategy_parameters = {})
        raise "Path #{path} does not exists" unless File.exists?(path)
        request = { :file => File.new(path, "rb") }
        request.merge!({ :iso2_slug => locale }) if locale
        request.merge!(strategy_parameters)
        @client.post(self.resources_url, request)
      end

      def pull_search_results(directory, filename, query, locale = nil)
        parameters = { :filename => filename, :query => query }
        parameters.merge!({ :iso2_slug => locale }) unless locale.nil? or locale.strip.empty?

        content = @client.get(search_url, parameters)
        save_to_file(File.join(directory, filename), content)
      end

      private

      def fetch
        @fetched = true
        response = @client.get @link
        project_hash = JSON.parse(response)
        links = project_hash["links"]
        link = links[0]["href"]
        weburl = links[1]["href"]
        translations_url = links[2]["href"]
        resources_url = links[3]["href"]
        exports_url = link + "/exports"
        search_url = links[4]["href"]

        init_attributes :title => project_hash["title"], :link => link,
                        :weburl => weburl,
                        :owner => project_hash["owner_email"], :description => project_hash["description"],
                        :project_locales => project_hash["project_locales"],
                        :translations_url => translations_url, :resources_url => resources_url,
                        :exports_url => exports_url, :search_url => search_url
      end

      def init_attributes(attributes)
        attributes.each_pair do |key, value|
          unless self.instance_variable_get("@#{key}")
            self.send "#{key}=", value
          end
        end
      end

      def save_to_file(path, content)
        File.open(path, 'w+') { |f| f.write(content.force_encoding("utf-8")) }
      end

      def resource_has_locale(resource, locale_as_filter)
        resource.locale == locale_as_filter
      end
    end
  end
end
