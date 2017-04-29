require 'bundler'
Bundler.setup

require 'rake'
require 'rake/testtask'
require 'ci/reporter/rake/minitest'

require 'pp'
require 'colored'
require 'json'

# change the file: users/username/.bcl/config.yml
# to the ID of the BCL group you want your measures to go into
# get the group id number from the URL of the group on BCL
# https://bcl.nrel.gov/node/37347 - the group ID here is 37347
# you must be an administrator or editor member of a group to
# upload content to that group

# Get latest installed version of openstudio.exe
os_clis = Dir["C:/openstudio-*/bin/openstudio.exe"] + Dir["/usr/bin/openstudio"] + Dir["/usr/local/bin/openstudio"]
if os_clis.size == 0
    puts "ERROR: Could not find the openstudio binary. You may need to install the OpenStudio Command Line Interface."
    exit
end
os_cli = os_clis[-1]

namespace :measures do
  desc 'Generate measures to prepare for upload to BCL '
  task :generate do
    require 'bcl'
    name_hash = replace_name_in_measure_xmls()
    # verify staged directory exists
    FileUtils.mkdir_p('./staged')
    dirs = Dir.glob('./measures/*')
    dirs.each do |dir|
      next if dir.include?('Rakefile')
      current_d = Dir.pwd
      measure_name = File.basename(dir)
      puts "Generating #{measure_name}"

      Dir.chdir(dir)
      # puts Dir.pwd

      destination = "../../staged/#{measure_name}.tar.gz"
      FileUtils.rm(destination) if File.exist?(destination)
      files = Pathname.glob('**/*')
      files.each do |f|
        puts "  #{f}"
      end
      paths = []
      files.each do |file|
        paths << file.to_s
      end

      BCL.tarball(destination, paths)
      Dir.chdir(current_d)
    end
    revert_name_in_measure_xmls(name_hash)
  end

  desc 'Push generated measures to the BCL group defined in .bcl/config.yml'
  task :push do
    require 'bcl'
    # grab all the tar files and push to bcl
    measures = []
    paths = Pathname.glob('./staged/*.tar.gz')
    paths.each do |path|
      puts path
      measures << path.to_s
    end
    bcl = BCL::ComponentMethods.new
    bcl.login
    bcl.push_contents(measures, true, 'nrel_measure')
  end

  desc 'update generated measures on the BCL'
  task :update do
    require 'bcl'
    # grab all the tar files and push to bcl
    measures = []
    paths = Pathname.glob('./staged/*.tar.gz')
    paths.each do |path|
      puts path
      measures << path.to_s
    end
    bcl = BCL::ComponentMethods.new
    bcl.login
    bcl.update_contents(measures, true)
  end

  desc 'test the BCL login credentials defined in .bcl/config.yml'
  task :test_bcl_login do
    require 'bcl'
    bcl = BCL::ComponentMethods.new
    bcl.login
  end

  desc 'create JSON metadata files'
  task :create_measure_jsons do
    require 'bcl'
    bcl = BCL::ComponentMethods.new

    Dir['./**/measure.rb'].each do |m|
      puts "Parsing #{m}"
      j = bcl.parse_measure_file(nil, m)
      m_j = "#{File.join(File.dirname(m), File.basename(m, '.*'))}.json"
      puts "Writing #{m_j}"
      File.open(m_j, 'w') { |f| f << JSON.pretty_generate(j) }
    end
  end

  desc 'make csv file of measures'
  task create_measure_csv: [:create_measure_jsons] do
    require 'CSV'
    require 'bcl'

    b = BCL::ComponentMethods.new
    new_csv_file = './measures_spreadsheet.csv'
    FileUtils.rm_f(new_csv_file) if File.exist?(new_csv_file)
    csv = CSV.open(new_csv_file, 'w')
    Dir.glob('./**/measure.json').each do |file|
      puts "Parsing Measure JSON for CSV #{file}"
      json = JSON.parse(File.read(file), symbolize_names: true)
      b.translate_measure_hash_to_csv(json).each { |r| csv << r }
    end

    csv.close
  end
end # end the :measures namespace

namespace :test do

  desc 'Run unit tests for all measures'
  Rake::TestTask.new('all') do |t|
    t.libs << 'test'
    t.test_files = Dir['measures/*/tests/*.rb']
    t.warning = false
    t.verbose = true
  end
  
  desc 'regenerate test osm files from osw files'
  task :regenerate_osms do

    num_tot = 0
    num_success = 0
    
    osw_path = File.expand_path("../test/osw_files/", __FILE__)
  
    # Generate hash that maps osw's to measures
    osw_map = {}
    #measures = ["ResidentialHVACSizing"] # Use this to specify individual measures (instead of all measures on the following line)
    measures = Dir.entries(File.expand_path("../measures/", __FILE__)).select {|entry| File.directory? File.join(File.expand_path("../measures/", __FILE__), entry) and !(entry == '.' || entry == '..') }
    measures.each do |m|
        testrbs = Dir[File.expand_path("../measures/#{m}/tests/*.rb", __FILE__)]
        if testrbs.size == 1
            # Get osm's specified in the test rb
            testrb = testrbs[0]
            osms = get_osms_listed_in_test(testrb)
            osms.each do |osm|
                osw = File.basename(osm).gsub('.osm','.osw')
                if not osw_map.keys.include?(osw)
                    osw_map[osw] = []
                end
                osw_map[osw] << m
            end
        elsif testrbs.size > 1
            puts "ERROR: Multiple .rb files found in #{m} tests dir."
            exit
      end
    end

    osw_files = Dir.entries(osw_path).select {|entry| entry.end_with?(".osw") and !osw_map[entry].nil?}
    if File.exists?(File.expand_path("../log", __FILE__))
        FileUtils.rm(File.expand_path("../log", __FILE__))
    end

    osw_files.each do |osw|

        # Generate osm from osw
        osw_filename = osw
        num_tot += 1
        
        puts "[#{num_tot}/#{osw_map.size}] Regenerating osm from #{osw}..."
        osw = File.expand_path("../test/osw_files/#{osw}", __FILE__)
        osm = File.expand_path("../test/osw_files/run/in.osm", __FILE__)
        command = "\"#{os_cli}\" run -w #{osw} -m >> log"
        for _retry in 1..3
            system(command)
            break if File.exists?(osm)
        end
        if not File.exists?(osm)
            puts "  ERROR: Could not generate osm."
            exit
        end

        # Add auto-generated message to top of file
        # Update EPW file paths to be relative for the CirceCI machine
        file_text = File.readlines(osm)
        File.open(osm, "w") do |f|
            f.write("!- NOTE: Auto-generated from #{osw.gsub(File.dirname(__FILE__), "")}\n")
            file_text.each do |file_line|
                if file_line.strip.start_with?("file:///")
                    file_data = file_line.split('/')
                    file_line = file_data[0] + "../tests/" + file_data[-1]
                end
                f.write(file_line)
            end
        end

        # Copy to appropriate measure test dirs
        osm_filename = osw_filename.gsub(".osw", ".osm")
        num_copied = 0
        osw_map[osw_filename].each do |measure|
            measure_test_dir = File.expand_path("../measures/#{measure}/tests/", __FILE__)
            if not Dir.exists?(measure_test_dir)
                puts "  ERROR: Could not copy osm to #{measure_test_dir}."
                exit
            end
            FileUtils.cp(osm, File.expand_path("#{measure_test_dir}/#{osm_filename}", __FILE__))
            num_copied += 1
        end
        puts "  Copied to #{num_copied} measure(s)."
        num_success += 1

        # Clean up
        run_dir = File.expand_path("../test/osw_files/run", __FILE__)
        if Dir.exists?(run_dir)
            FileUtils.rmtree(run_dir)
        end
        if File.exists?(File.expand_path("../test/osw_files/out.osw", __FILE__))
            FileUtils.rm(File.expand_path("../test/osw_files/out.osw", __FILE__))
        end
    end
    
    # Remove any extra osm's in the measures test dirs
    measures.each do |m|
        osms = Dir[File.expand_path("../measures/#{m}/tests/*.osm", __FILE__)]
        osms.each do |osm|
            osw = File.basename(osm).gsub('.osm','.osw')
            if not osw_map[osw].nil? and not osw_map[osw].include?(m)
                puts "Extra file #{osw} found in #{m}/tests. Do you want to delete it? (y/n)"
                input = STDIN.gets.strip.downcase
                next if input != "y"
                FileUtils.rm(osm)
                puts "File deleted."
            end
        end
    end    
    
    puts "Completed. #{num_success} of #{num_tot} osm files were regenerated successfully."
    
  end

end

desc 'update all resources'
task :update_resources do

  measures_dir = File.expand_path("../measures/", __FILE__)
  
  measures = Dir.entries(measures_dir).select {|entry| File.directory? File.join(File.expand_path("../measures/", __FILE__), entry) and !(entry == '.' || entry == '..') }
  measures.each do |m|
    measurerb = File.expand_path("../measures/#{m}/measure.rb", __FILE__)
    
    # Get recursive list of resources required based on looking for 'require FOO' in rb files
    resources = get_requires_from_file(measurerb)

    # Add any additional resources specified in resource_to_measure_mapping.csv
    subdir_resources = {} # Handle resources in subdirs
    File.open(File.expand_path("../resources/resource_to_measure_mapping.csv", __FILE__)) do |file|
      file.each do |line|
        line = line.chomp.split(',').reject { |l| l.empty? }
        measure = line.delete_at(0)
        next if measure != m
        line.each do |resource|
          fullresource = File.expand_path("../resources/#{resource}", __FILE__)
          next if resources.include?(fullresource)
          resources << fullresource
          if resource != File.basename(resource)
            subdir_resources[File.basename(resource)] = resource
          end
        end
      end
    end
    
    # Add/update resource files as needed
    resources.each do |resource|
      if not File.exist?(resource)
        puts "Cannot find resource: #{resource}."
        next
      end
      r = File.basename(resource)
      dest_resource = File.expand_path("../measures/#{m}/resources/#{r}", __FILE__)
      measure_resource_dir = File.dirname(dest_resource)
      if not File.directory?(measure_resource_dir)
        FileUtils.mkdir_p(measure_resource_dir)
      end
      if not File.file?(dest_resource)
        FileUtils.cp(resource, measure_resource_dir)
        puts "Added #{r} to #{m}/resources."
      elsif not FileUtils.compare_file(resource, dest_resource)
        FileUtils.cp(resource, measure_resource_dir)
        puts "Updated #{r} in #{m}/resources."
      end
    end
    
    # Any extra resource files?
    if File.directory?(File.expand_path("../measures/#{m}/resources", __FILE__))
      Dir.foreach(File.expand_path("../measures/#{m}/resources", __FILE__)) do |item|
        next if item == '.' or item == '..'
        if subdir_resources.include?(item)
          item = subdir_resources[item]
        end
        resource = File.expand_path("../resources/#{item}", __FILE__)
        next if resources.include?(resource)
        item_path = File.expand_path("../measures/#{m}/resources/#{item}", __FILE__)
        if File.directory?(item_path)
            puts "Extra dir #{item} found in #{m}/resources. Do you want to delete it? (y/n)"
            input = STDIN.gets.strip.downcase
            next if input != "y"
            puts "deleting #{item_path}"
            FileUtils.rm_rf(item_path)
            puts "Dir deleted."
        else
            puts "Extra file #{item} found in #{m}/resources. Do you want to delete it? (y/n)"
            input = STDIN.gets.strip.downcase
            next if input != "y"
            FileUtils.rm(item_path)
            puts "File deleted."
        end
      end
    end
    
  end
  
  # Update measure xmls
  command = "\"#{os_cli}\" measure --update_all #{measures_dir} >> log"
  puts "Updating measure.xml files..."
  system(command)

end

desc 'Copy resources from OpenStudio-ResStock repo'
task :copy_resstock_resources do  
  extra_files = [
                 File.join("resources", "helper_methods.rb")
                ]  
  extra_files.each do |extra_file|
      puts "Copying #{extra_file}..."
      resstock_file = File.join(File.dirname(__FILE__), "..", "OpenStudio-ResStock", extra_file)
      hpxml_file = File.join(File.dirname(__FILE__), extra_file)
      if File.exists?(hpxml_file)
        FileUtils.rm(hpxml_file)
      end
      FileUtils.cp(resstock_file, hpxml_file)
  end  
end


desc 'Generates an OpenStudio Workflow OSW file with all measures in it, including descriptions'
task :generate_full_osw do  
  generate_osw_of_all_measures_in_order(os_cli)
end

# This function will generate an OpenStudio OSW
# with all the measures in it, in the order specific in /resources/measure-order.json
# All arguments are explicitly set with placeholders for those that don't have a default value
# The placeholder is "#{REQUIRED/OPTIONAL} - #{argument description}"
#
#@return [Bool] true if successful, false if not
def generate_osw_of_all_measures_in_order(os_cli)

	require 'openstudio'

  puts "Generating a full OSW"
  
  workflowJSON = OpenStudio::WorkflowJSON.new
  workflowJSON.setOswPath("test/osw_files/FullJSON.osw")
  workflowJSON.addMeasurePath("../../measures")
  workflowJSON.setSeedFile("../../seeds/EmptySeedModel.osm")
  
  # Prepare model path to pass it to the cli (convert to absolute)
  model_path = File.expand_path(workflowJSON.seedFile.get.to_s, workflowJSON.oswDir.to_s)
	
  
  # Check that there is no missing/extra measures in the measure-order.json
  # and get all_measures name (folders) in the correct order
  #
  # @Todo: here I'm getting a list of ALL measures in the order, but for some steps
  # @Todo: eg Geometry: you pick one of [SFA, SFD, MF]here are clearly alternatives
  # @Todo: we might to instead use the measure-order.json, loop on groups, steps in groups, and get measures[0] 
  
  all_measures = get_and_proof_measure_order_json(os_cli)
  if all_measures.size == 0
    exit
  end
  
  steps = OpenStudio::WorkflowStepVector.new
  
  all_measures.each do |measure|

		measure_path = File.expand_path(File.join("../../measures", measure), workflowJSON.oswDir.to_s) 
		
		# Prepare the cli command
    command = "\"#{os_cli}\" measure --compute_arguments #{model_path} #{measure_path}"
    
    puts "adding #{measure}"
    
    # The problem with this is that it's going to crash if it's not a model measure...
    measure_info =  `#{command}`
    if measure_info == ""
      command = "\"#{os_cli}\" measure --compute_arguments #{measure_path}"
      measure_info =  `#{command}`
    end
  	# Parse JSON and use hashrocket notation for keys
		measure_info_hash = JSON.parse(measure_info, {:symbolize_names => true})
		
		step = OpenStudio::MeasureStep.new(measure)
		step.setName(measure_info_hash[:display_name])
		step.setDescription(measure_info_hash[:description])
		
		# step.setModelerDescription(measure_info_hash[:modeler_description])
		
		# Get Measure Type
		measure_type = measure_info_hash[:attributes].select {|a| a[:name].downcase == "measure type"}[0][:value]
		step.setModelerDescription("[#{measure_type}] #{measure_info_hash[:modeler_description]}")

		# Loop on each argument
		measure_info_hash[:arguments].each do |arg|
			# If there is a default_value, use it
			if arg.key?(:default_value)
				step.setArgument(arg[:name], arg[:default_value])
			# Otherwise, if it's required
			elsif arg[:required]
				step.setArgument(arg[:name], "REQUIRED - #{arg[:description]}")
			# If it's not required
			# @Todo: determine whether we want to simply ommit the argument
			else
			 step.setArgument(arg[:name], "Optional - #{arg[:description]}")
			end
		end
  
  	# Push step in Steps
    steps.push(step)
  end 

  workflowJSON.setWorkflowSteps(steps)
  workflowJSON.save #FullJSON.osw")
  
  
end

# This function will check that all measure folders (in measures/) 
# are listed in the /resources/measure-order.json and vice versa
# and return the list of all measures used in the proper order
#
# @return [Array] of all measures used is successful, [] otherwise
def get_and_proof_measure_order_json(os_cli)
  # List all measures in measures/ folder
  beopt_measure_folder = File.expand_path("../measures/", __FILE__)
  all_measures = Dir.entries(beopt_measure_folder).select{|entry| !(entry.start_with? '.')}
  
  # Load json, and get all measures in there
  json_path = File.expand_path("../resources/measure-order.json", __FILE__)
  data_hash = JSON.parse(File.read(json_path))

  measures_json = []
  data_hash.each do |group|
    group["steps"].each do |step|
      measures_json += step["measures"]
    end 
  end
  
  is_correct = true
  # Check for missing in JSON file
  missing_in_json = all_measures - measures_json
  if missing_in_json.size > 0
    puts "There are #{missing_in_json.size} that are present in the `/measures` folder but not in the `measure-order.json`"
    missing_in_json.each do |missing|
      puts missing
    end
    is_correct = false
  end

  # Check for measures in JSON that don't have a corresponding folder
  extra_in_json = measures_json - all_measures
  if extra_in_json.size > 0
    puts "There are #{extra_in_json.size} that are present in the `measure-order.json` but not in the `/measures` folder"
    extra_in_json.each do |extra|
      puts extra
    end
    is_correct = false
  end
  
  if is_correct
    return measures_json
  else
    return []
  end
end

def get_requires_from_file(filerb)
  requires = []
  if not File.exists?(filerb)
    return requires
  end
  File.open(filerb) do |file|
    file.each do |line|
      line.strip!
      next if line.nil?
      next if not (line.start_with?("require \"\#{File.dirname(__FILE__)}/") or line.start_with?("require\"\#{File.dirname(__FILE__)}/"))
      line.chomp!("\"")
      d = line.split("/")
      requirerb = File.expand_path("../resources/#{d[-1].to_s}.rb", __FILE__)
      requires << requirerb
    end   
  end
  # Recursively look for additional requirements
  requires.each do |requirerb|
    get_requires_from_file(requirerb).each do |rb|
      next if requires.include?(rb)
      requires << rb
    end
  end
  return requires
end

def get_osms_listed_in_test(testrb)
    osms = []
    if not File.exists?(testrb)
      return osms
    end
    str = File.readlines(testrb).join("\n")
    osms = str.scan(/\w+\.osm/)
    return osms.uniq
end

def replace_name_in_measure_xmls()
    # This method replaces the <name> element in measure.xml
    # with the <display_name> value and returns the original
    # <name> values in a hash.
    # This is temporary code since the BCL currently looks
    # at the <name> element, rather than the <display_name>
    # element, in the measure.xml file. The BCL will be fixed
    # at some future point.
    name_hash = {}
    require 'rexml/document'
    require 'rexml/xpath'
    Dir.glob('./measures/*').each do |dir|
      next if dir.include?('Rakefile')
      measure_xml = File.absolute_path(File.join(dir, "measure.xml"))
      xmldoc = REXML::Document.new(File.read(measure_xml))
      orig_name = REXML::XPath.first(xmldoc, "//measure/name").text
      display_name = REXML::XPath.first(xmldoc, "//measure/display_name").text
      REXML::XPath.each(xmldoc, "//measure/name") do |node|
        node.text = display_name
      end
      xmldoc.write(File.open(measure_xml, "w"))
      name_hash[measure_xml] = orig_name
    end
    return name_hash
end

def revert_name_in_measure_xmls(name_hash)
    # This method reverts the <name> element in measure.xml
    # to its original value.
    require 'rexml/document'
    require 'rexml/xpath'
    Dir.glob('./measures/*').each do |dir|
      next if dir.include?('Rakefile')
      measure_xml = File.absolute_path(File.join(dir, "measure.xml"))
      xmldoc = REXML::Document.new(File.read(measure_xml))
      REXML::XPath.each(xmldoc, "//measure/name") do |node|
        node.text = name_hash[measure_xml]
      end
      xmldoc.write(File.open(measure_xml, "w"))
    end
end