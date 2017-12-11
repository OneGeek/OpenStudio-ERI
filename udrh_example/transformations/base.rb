class Transformation

  def initialize(hpxml_file_path, type, debug=false)
    @debug=debug
    if type.downcase == 'hpxml'
      @typerb = 'hpxml.rb'
      require_relative @typerb
      @object = eval("HPXMLTransformation").new(hpxml_file_path)
    elsif type.downcase == 'ekotrope'
      @typerb = 'ekotrope.rb'
      require_relative @typerb
      @object = eval("EkotropeTransformation").new(hpxml_file_path)
    end
  end
  
  def self.AGWallUo(location, uo_value)
    criteria = [
                'Cond->Ambient',
                'Cond->Garage',
                'Cond->OpenCrawl',
                'Cond->Attic',
                'Cond->UncondBasement',
                'Cond->EnclosedCrawl',
                'UncondBasement->Ambient',
                'UncondBasement->Garage',
                'UncondBasement->OpenCrawl',
                'EnclosedCrawl->Ambient',
                'EnclosedCrawl->Garage',
                'EnclosedCrawl->OpenCrawl',
                'All',
                'All/Cond->Any',
                'All/Uncond->Any',
                'All/Cond->Outdoor',
                'All/Cond->OutdoorOrAmbient',
                'All/Cond->Buffer',
                'All/Buffer->OutdoorOrAmbient',
                'All/UncondBasement->OutdoorOrAmbient',
                'All/EnclosedCrawl->OutdoorOrAmbient',
                'All/Cond->BufferOrOutdoor',
               ]
    if not criteria.include? location
      puts "Error: #{__method__} Location not valid: '#{location}'."
      exit
    end
    if uo_value.to_f <= 0
      puts "Error: #{__method__} UoValue not valid: '#{uo_value}'."
      exit
    end
  end
  
  def self.AGWallLibrary(location, library_name)
    # TODO
  end
  
  def self.GetClimateZone()
    # Needs to be implemented by inherited class
  end
  
  def self.WriteFile(out_path)
    # Needs to be implemented by inherited class
  end

  def method_missing(*args)
    method_name = args[0]
    if not Transformation.respond_to? method_name
      puts "Error: Invalid command specified: '#{method_name}'."
      exit
    end
    if not @object.respond_to? method_name
      puts "Error: #{@typerb} does not implement the command: '#{method_name}'."
      exit
    end
    Transformation.send(*args)
    @object.send(*args)
  end

end