require_relative 'transformations/base.rb'


def run_ruleset(input, output, type)
  h = Transformation.new(input, type)
  climate_zone = h.GetClimateZone()

  # Above Grade Walls
  if ['1A', '1B', '1C', '2A', '2B', '2C', '3A', '3B', '3C', '4A', '4B'].include? climate_zone
    h.AGWallUo('All', 0.082)
  elsif ['4C', '5A', '5B', '5C', '6A', '6B', '6C'].include? climate_zone
    h.AGWallUo('All', 0.060)
  elsif ['7', '8'].include? climate_zone
    h.AGWallUo('All', 0.057)
  end
  
  # Example errors:
  # h.AGWallUo('Foo->Bar', 0.057) # Error: AGWallUo Location not valid: 'Foo->Bar'.
  # h.MissingAGWallUo('All', 0.057) # Error: Invalid command specified: 'MissingAGWallUo'.
  # h.AGWallLibrary('All', 'R-13 Wood Stud Wall') # Error: hpxml does not implement the command: 'AGWallLibrary'.

  h.WriteFile(output)
end


# CLI arguments
require 'optparse'
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename(__FILE__)} -i input.file -o output.file -t type"

  opts.on('-i', '--input <FILE>', 'input file') do |t|
    options[:input] = t
  end

  opts.on('-o', '--output <FILE>', 'output file') do |t|
    options[:output] = t
  end
  
  opts.on('-t', '--type <TYPE>', 'hpxml|ekotrope') do |t|
    options[:type] = t
  end
  
  opts.on_tail('-h', '--help', 'Display help') do
    puts opts
    exit
  end

end.parse!

run_ruleset(options[:input], options[:output], options[:type])