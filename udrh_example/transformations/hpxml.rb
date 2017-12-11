class HPXMLTransformation

  def initialize(input_file_path)
    require 'rexml/document'
    require 'rexml/xpath'
    @hpxml_doc = REXML::Document.new(File.read(input_file_path))
  end

  def AGWallUo(location, uo_value)
    @hpxml_doc.elements.each('/HPXML/Building/BuildingDetails/Enclosure/Walls/Wall') do |wall|
      interior_adjacent_to = wall.elements['extension/InteriorAdjacentTo'].text
      exterior_adjacent_to = wall.elements['extension/ExteriorAdjacentTo'].text
      # TODO: Skip based on location criteria
      wall.elements.delete('Insulation/Layer[InstallationType="cavity"]')
      wall.elements.delete('Insulation/Layer[InstallationType="continuous"]')
      rvalue = REXML::Element.new('AssemblyEffectiveRValue')
      rvalue.text = 1.0/uo_value
      wall << rvalue
    end
  end
  
  def GetClimateZone()
    return @hpxml_doc.elements['/HPXML/Building/BuildingDetails/ClimateandRiskZones/ClimateZoneIECC[Year="2006"]/ClimateZone'].text
  end
  
  def WriteFile(out_path)
    formatter = REXML::Formatters::Pretty.new(2)
    formatter.compact = true
    formatter.width = 1000
    File.open(out_path, 'w') do |f|
      formatter.write(@hpxml_doc, f)
    end
  end

end
