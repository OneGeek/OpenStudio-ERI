start_time = Time.now

require 'optparse'
require 'csv'
require 'pathname'
require 'fileutils'
require 'parallel'
require 'openstudio'
require_relative "../measures/301EnergyRatingIndexRuleset/resources/constants"
require_relative "../measures/301EnergyRatingIndexRuleset/resources/xmlhelper"
require_relative "../measures/301EnergyRatingIndexRuleset/resources/util"
require_relative "../measures/301EnergyRatingIndexRuleset/resources/unit_conversions"

# TODO: Add error-checking
# TODO: Add standardized reporting of errors

designs = [
           Constants.CalcTypeERIRatedHome,
           Constants.CalcTypeERIReferenceHome,
           #Constants.CalcTypeERIIndexAdjustmentDesign,
          ]

basedir = File.expand_path(File.dirname(__FILE__))
      
def recreate_path(path)
  if Dir.exists?(path)
    FileUtils.rm_r(path)
  end
  for retries in 1..50
    break if not Dir.exists?(path)
    sleep(0.1)
  end
  Dir.mkdir(path)
end

def create_osw(design, basedir, resultsdir, options)

  design_str = design.gsub(' ','')

  # Create dir
  designdir = File.join(basedir, design_str)
  recreate_path(designdir)
  
  # Create OSW
  osw_path = File.join(designdir, "run.osw")
  osw = OpenStudio::WorkflowJSON.new
  osw.setOswPath(osw_path)
  osw.addMeasurePath("../../measures")
  osw.setSeedFile("../../seeds/EmptySeedModel.osm")
  
  # Add measures (w/args) to OSW
  schemas_dir = File.absolute_path(File.join(basedir, "..", "hpxml_schemas"))
  output_hpxml_path = File.join(resultsdir, design_str + ".xml")
  measures = {}
  measures['301EnergyRatingIndexRuleset'] = {}
  measures['301EnergyRatingIndexRuleset']['calc_type'] = design
  measures['301EnergyRatingIndexRuleset']['hpxml_file_path'] = options[:hpxml]
  #measures['301EnergyRatingIndexRuleset']['schemas_dir'] = schemas_dir # FIXME
  measures['301EnergyRatingIndexRuleset']['hpxml_output_file_path'] = output_hpxml_path
  if options[:debug]
    measures['301EnergyRatingIndexRuleset']['debug'] = 'true'
    measures['301EnergyRatingIndexRuleset']['osm_output_file_path'] = output_hpxml_path.gsub(".xml",".osm")
  end
  steps = OpenStudio::WorkflowStepVector.new
  measures.keys.each do |measure|
    step = OpenStudio::MeasureStep.new(measure)
    step.setName(measure)
    measures[measure].each do |arg,val|
      step.setArgument(arg, val)
    end
    steps.push(step)
  end  
  osw.setWorkflowSteps(steps)
  
  # Save OSW
  osw.save
  
  return osw_path, output_hpxml_path
  
end

def run_osw(osw_path, show_debug=false)

  log_str = ''
  if not show_debug
    # Redirect to a log file
    log_str = " >> \"#{osw_path.gsub('.osw','.log')}\""
  end
  
  # FIXME: Push changes upstream to OpenStudio-workflow gem
  gem_str = '-I ../gems/OpenStudio-workflow-gem/lib/ '

  cli_path = OpenStudio.getOpenStudioCLI
  command = "\"#{cli_path}\" #{gem_str}run -w \"#{osw_path}\"#{log_str}"
  system(command)
  
  return File.join(File.dirname(osw_path), "run", "eplusout.sql")
  
end

def get_sql_query_result(sqlFile, query)
  result = sqlFile.execAndReturnFirstDouble(query)
  if result.is_initialized
    return UnitConversions.convert(result.get, "GJ", "MBtu")
  end
  return 0
end

def get_sql_result(sqlValue, design)
  if sqlValue.is_initialized
    return UnitConversions.convert(sqlValue.get, "GJ", "MBtu")
  end
  fail "ERROR: Simulation unsuccessful for #{design}."
end

def parse_sql(design, sql_path, output_hpxml_path)
  if not File.exists?(sql_path)
    fail "ERROR: Simulation unsuccessful for #{design}."
  end
  
  sqlFile = OpenStudio::SqlFile.new(sql_path, false)
  
  sim_output = {}
  sim_output[:hpxml] = output_hpxml_path
  sim_output[:allTotal] = get_sql_result(sqlFile.totalSiteEnergy, design)
  
  # Electricity categories
  sim_output[:elecTotal] = get_sql_result(sqlFile.electricityTotalEndUses, design)
  sim_output[:elecHeating] = get_sql_result(sqlFile.electricityHeating, design)
  sim_output[:elecCooling] = get_sql_result(sqlFile.electricityCooling, design)
  sim_output[:elecIntLighting] = get_sql_result(sqlFile.electricityInteriorLighting, design)
  sim_output[:elecExtLighting] = get_sql_result(sqlFile.electricityExteriorLighting, design)
  sim_output[:elecAppliances] = get_sql_result(sqlFile.electricityInteriorEquipment, design)
  sim_output[:elecFans] = get_sql_result(sqlFile.electricityFans, design)
  sim_output[:elecPumps] = get_sql_result(sqlFile.electricityPumps, design)
  sim_output[:elecHotWater] = get_sql_result(sqlFile.electricityWaterSystems, design)
  
  # Fuel categories
  sim_output[:ngTotal] = get_sql_result(sqlFile.naturalGasTotalEndUses, design)
  sim_output[:ngHeating] = get_sql_result(sqlFile.naturalGasHeating, design)
  sim_output[:ngAppliances] = get_sql_result(sqlFile.naturalGasInteriorEquipment, design)
  sim_output[:ngHotWater] = get_sql_result(sqlFile.naturalGasWaterSystems, design)
  sim_output[:otherTotal] = get_sql_result(sqlFile.otherFuelTotalEndUses, design)
  sim_output[:otherHeating] = get_sql_result(sqlFile.otherFuelHeating, design)
  sim_output[:otherAppliances] = get_sql_result(sqlFile.otherFuelInteriorEquipment, design)
  sim_output[:otherHotWater] = get_sql_result(sqlFile.otherFuelWaterSystems, design)
  sim_output[:fuelTotal] = sim_output[:ngTotal] + sim_output[:otherTotal]
  sim_output[:fuelHeating] = sim_output[:ngHeating] + sim_output[:otherHeating]
  sim_output[:fuelAppliances] = sim_output[:ngAppliances] + sim_output[:otherAppliances]
  sim_output[:fuelHotWater] = sim_output[:ngHotWater] + sim_output[:otherHotWater]

  # Other - PV
  query = "SELECT -1*Value FROM TabularDataWithStrings WHERE ReportName='AnnualBuildingUtilityPerformanceSummary' AND ReportForString='Entire Facility' AND TableName='Electric Loads Satisfied' AND RowName='Total On-Site Electric Sources' AND ColumnName='Electricity' AND Units='GJ'"
  sim_output[:elecPV] = get_sql_query_result(sqlFile, query)
  
  # Other - Fridge
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName LIKE '#{Constants.ObjectNameRefrigerator}%' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
  sim_output[:elecFridge] = get_sql_query_result(sqlFile, query)
  
  # Other - Dishwasher
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName LIKE '#{Constants.ObjectNameDishwasher}%' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
  sim_output[:elecDishwasher] = get_sql_query_result(sqlFile, query)
  
  # Other - Clothes Washer
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName LIKE '#{Constants.ObjectNameClothesWasher}%' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
  sim_output[:elecClothesWasher] = get_sql_query_result(sqlFile, query)
  
  # Other - Clothes Dryer
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName LIKE '#{Constants.ObjectNameClothesDryer(nil)}%' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
  sim_output[:elecClothesDryer] = get_sql_query_result(sqlFile, query)
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Gas' AND RowName LIKE '#{Constants.ObjectNameClothesDryer(nil)}%' AND ColumnName='Gas Annual Value' AND Units='GJ'"
  sim_output[:ngClothesDryer] = get_sql_query_result(sqlFile, query)
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Other' AND RowName LIKE '#{Constants.ObjectNameClothesDryer(nil)}%' AND ColumnName='Annual Value' AND Units='GJ'"
  sim_output[:otherClothesDryer] = get_sql_query_result(sqlFile, query)
  sim_output[:fuelClothesDryer] = sim_output[:ngClothesDryer] + sim_output[:otherClothesDryer]
  
  # Other - MELS
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName LIKE '#{Constants.ObjectNameMiscPlugLoads}%' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
  sim_output[:elecMELs] = get_sql_query_result(sqlFile, query)
  
  # Other - Range/Oven
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName LIKE '#{Constants.ObjectNameCookingRange(nil)}%' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
  sim_output[:elecRangeOven] = get_sql_query_result(sqlFile, query)
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Gas' AND RowName LIKE '#{Constants.ObjectNameCookingRange(nil)}%' AND ColumnName='Gas Annual Value' AND Units='GJ'"
  sim_output[:ngRangeOven] = get_sql_query_result(sqlFile, query)
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Other' AND RowName LIKE '#{Constants.ObjectNameCookingRange(nil)}%' AND ColumnName='Annual Value' AND Units='GJ'"
  sim_output[:otherRangeOven] = get_sql_query_result(sqlFile, query)
  sim_output[:fuelRangeOven] = sim_output[:ngRangeOven] + sim_output[:otherRangeOven]
  
  # Other - Ceiling Fans
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName LIKE '#{Constants.ObjectNameCeilingFan}%' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
  sim_output[:elecCeilingFan] = get_sql_query_result(sqlFile, query)
  
  # Other - Mechanical Ventilation
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName LIKE '#{Constants.EndUseMechVentFan}%' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
  sim_output[:elecMechVent] = get_sql_query_result(sqlFile, query)
  
  # Other - Recirculation pump
  query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName LIKE '#{Constants.ObjectNameHotWaterRecircPump}%' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
  sim_output[:elecRecircPump] = get_sql_query_result(sqlFile, query)
  sim_output[:elecAppliances] -= sim_output[:elecRecircPump]
  
  # Other - Space Heating Load
  vars = "'" + BuildingLoadVars.get_space_heating_load_vars.join("','") + "'"
  query = "SELECT SUM(ABS(VariableValue)/1000000000) FROM ReportVariableData WHERE ReportVariableDataDictionaryIndex IN (SELECT ReportVariableDataDictionaryIndex FROM ReportVariableDataDictionary WHERE VariableType='Sum' AND IndexGroup='System' AND TimestepType='Zone' AND VariableName IN (#{vars}) AND ReportingFrequency='Run Period' AND VariableUnits='J')"
  sim_output[:loadHeating] = get_sql_query_result(sqlFile, query)
  
  # Other - Space Cooling Load
  vars = "'" + BuildingLoadVars.get_space_cooling_load_vars.join("','") + "'"
  query = "SELECT SUM(ABS(VariableValue)/1000000000) FROM ReportVariableData WHERE ReportVariableDataDictionaryIndex IN (SELECT ReportVariableDataDictionaryIndex FROM ReportVariableDataDictionary WHERE VariableType='Sum' AND IndexGroup='System' AND TimestepType='Zone' AND VariableName IN (#{vars}) AND ReportingFrequency='Run Period' AND VariableUnits='J')"
  sim_output[:loadCooling] = get_sql_query_result(sqlFile, query)
  
  # Other - Water Heating Load
  vars = "'" + BuildingLoadVars.get_water_heating_load_vars.join("','") + "'"
  query = "SELECT SUM(ABS(VariableValue)/1000000000) FROM ReportVariableData WHERE ReportVariableDataDictionaryIndex IN (SELECT ReportVariableDataDictionaryIndex FROM ReportVariableDataDictionary WHERE VariableType='Sum' AND IndexGroup='System' AND TimestepType='Zone' AND VariableName IN (#{vars}) AND ReportingFrequency='Run Period' AND VariableUnits='J')"
  sim_output[:loadHotWater] = get_sql_query_result(sqlFile, query)
  
  # Error Checking
  tolerance = 0.1 # MMBtu
  
  sum_fuels = (sim_output[:elecTotal] + sim_output[:fuelTotal])
  if (sim_output[:allTotal] - sum_fuels).abs > tolerance
    fail "ERROR: Fuels do not sum to total (#{sum_fuels.round(1)} vs #{sim_output[:allTotal].round(1)})."
  end
  
  sum_elec_categories = (sim_output[:elecHeating] + sim_output[:elecCooling] + 
                         sim_output[:elecIntLighting] + sim_output[:elecExtLighting] + 
                         sim_output[:elecAppliances] + sim_output[:elecFans] + 
                         sim_output[:elecPumps] + sim_output[:elecHotWater] + 
                         sim_output[:elecRecircPump])
  if (sim_output[:elecTotal] - sum_elec_categories).abs > tolerance
    fail "ERROR: Electric category end uses do not sum to total.\n#{sim_output.to_s}"
  end
  
  sum_fuel_categories = (sim_output[:fuelHeating] + sim_output[:fuelAppliances] + 
                         sim_output[:fuelHotWater])
  if (sim_output[:fuelTotal] - sum_fuel_categories).abs > tolerance
    fail "ERROR: Fuel category end uses do not sum to total.\n#{sim_output.to_s}"
  end
  
  sum_elec_appliances = (sim_output[:elecFridge] + sim_output[:elecDishwasher] +
                     sim_output[:elecClothesWasher] + sim_output[:elecClothesDryer] +
                     sim_output[:elecMELs] + sim_output[:elecRangeOven] +
                     sim_output[:elecCeilingFan] + sim_output[:elecMechVent])
  if (sim_output[:elecAppliances] - sum_elec_appliances).abs > tolerance
    fail "ERROR: Electric appliances do not sum to total.\n#{sim_output.to_s}"
  end
  
  sum_fuel_appliances = (sim_output[:fuelClothesDryer] + sim_output[:fuelRangeOven])
  if (sim_output[:fuelAppliances] - sum_fuel_appliances).abs > tolerance
    fail "ERROR: Fuel appliances do not sum to total.\n#{sim_output.to_s}"
  end
  
  return sim_output
  
end

def get_heating_fuel(hpxml_doc)
  heat_fuel = nil
  
  heating_system = hpxml_doc.elements["/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem"]
  heat_pump_system = hpxml_doc.elements["/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatPump"]
  
  if heating_system.nil? and heat_pump_system.nil?
    fail "ERROR: No heating system found."
  elsif not heating_system.nil? and not heat_pump_system.nil?
    fail "ERROR: Multiple heating systems found."
  elsif not heating_system.nil?
    heat_fuel = XMLHelper.get_value(heating_system, "HeatingSystemFuel")
  elsif not heat_pump_system.nil?
    heat_fuel = 'electricity'
  end
  
  if heat_fuel.nil?
    fail "ERROR: No heating system fuel type found."
  end

  return heat_fuel
end

def get_dhw_fuel(hpxml_doc)
  dhw_fuel = nil
  
  dhw_system = hpxml_doc.elements["/HPXML/Building/BuildingDetails/Systems/WaterHeating/WaterHeatingSystem"]
  
  if dhw_system.nil?
    fail "ERROR: No water heating system found."
  else
    dhw_fuel = XMLHelper.get_value(dhw_system, "FuelType")
  end
  
  if dhw_fuel.nil?
    fail "ERROR: No water heating system fuel type found."
  end
  
  return dhw_fuel
end

def get_dse_heat_cool(hpxml_doc)
  
  dse_heat = XMLHelper.get_value(hpxml_doc, "/HPXML/Building/BuildingDetails/Systems/HVAC/HVACDistribution/AnnualHeatingDistributionSystemEfficiency")
  dse_cool = XMLHelper.get_value(hpxml_doc, "/HPXML/Building/BuildingDetails/Systems/HVAC/HVACDistribution/AnnualCoolingDistributionSystemEfficiency")
  
  if dse_heat.nil?
    fail "ERROR: Heating distribution system efficiency not found."
  elsif dse_cool.nil?
    fail "ERROR: Cooling distribution system efficiency not found."
  end
  
  return Float(dse_heat), Float(dse_cool)
  
end

def get_eec_value_numerator(unit)
  if ['HSPF','SEER','EER'].include? unit
    return 3.413
  elsif ['AFUE','COP','Percent','EF'].include? unit
    return 1.0
  end
  fail "ERROR: Unexpected unit #{unit}."
end

def get_eec_heat(hpxml_doc)
  eec_heat = nil
  
  heating_system = hpxml_doc.elements["/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatingSystem"]
  heat_pump_system = hpxml_doc.elements["/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatPump"]
  
  [heating_system, heat_pump_system].each do |sys|
    next if sys.nil?
    ['HSPF','COP','AFUE','Percent'].each do |unit|
      if sys == heating_system
        value = XMLHelper.get_value(sys, "AnnualHeatingEfficiency[Units='#{unit}']/Value")
      elsif sys == heat_pump_system
        value = XMLHelper.get_value(sys, "AnnualHeatEfficiency[Units='#{unit}']/Value")
      end
      next if value.nil?
      if not eec_heat.nil?
        fail "ERROR: Multiple heating system efficiency values found."
      end
      eec_heat = get_eec_value_numerator(unit) / value.to_f
    end
  end

  if eec_heat.nil?
    fail "ERROR: No heating system efficiency value found."
  end

  return eec_heat
end

def get_eec_cool(hpxml_doc)
  eec_cool = nil
  
  cooling_system = hpxml_doc.elements["/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/CoolingSystem"]
  heat_pump_system = hpxml_doc.elements["/HPXML/Building/BuildingDetails/Systems/HVAC/HVACPlant/HeatPump"]
  
  [cooling_system, heat_pump_system].each do |sys|
    next if sys.nil?
    ['SEER','COP','EER'].each do |unit|
      if sys == cooling_system  
        value = XMLHelper.get_value(sys, "AnnualCoolingEfficiency[Units='#{unit}']/Value")
      elsif sys == heat_pump_system
        value = XMLHelper.get_value(sys, "AnnualCoolEfficiency[Units='#{unit}']/Value")
      end
      next if value.nil?
      if not eec_cool.nil?
        fail "ERROR: Multiple cooling system efficiency values found."
      end
      eec_cool = get_eec_value_numerator(unit) / value.to_f
    end
  end
  
  if eec_cool.nil?
    fail "ERROR: No cooling system efficiency value found."
  end
  
  return eec_cool
end

def get_eec_dhw(hpxml_doc)
  eec_dhw = nil
  
  dhw_system = hpxml_doc.elements["/HPXML/Building/BuildingDetails/Systems/WaterHeating/WaterHeatingSystem"]
  
  [dhw_system].each do |sys|
    next if sys.nil?
    value = XMLHelper.get_value(sys, "EnergyFactor")
    value_adj = XMLHelper.get_value(sys, "extension/PerformanceAdjustmentEnergyFactor")
    if not value.nil? and not value_adj.nil?
      eec_dhw = get_eec_value_numerator('EF') / (value.to_f * value_adj.to_f)
    end
  end
  
  if eec_dhw.nil?
    fail "ERROR: No water heating system efficiency value found."
  end
  
  return eec_dhw
end

def dhw_adjustment(hpxml_doc)
  # FIXME: Can we modify EF/COP/etc. efficiencies like we do for DSE, so that we don't need to post-process?
  # FIXME: Double-check this only applies to the Rated Home
  hwdist = hpxml_doc.elements["/HPXML/Building/BuildingDetails/Systems/WaterHeating/HotWaterDistribution"]
  return Float(XMLHelper.get_value(hwdist, "extension/EnergyConsumptionAdjustmentFactor"))
end

def verify_user_inputs(rated_hpxml_doc, ref_hpxml_doc, resultsdir)

  # User Input Verification Requirements
  msgs = []
  has_error = false
  
  rated_building = rated_hpxml_doc.elements["/HPXML/Building"]
  ref_building = ref_hpxml_doc.elements["/HPXML/Building"]
  
  cfa = Float(XMLHelper.get_value(rated_building, "BuildingDetails/BuildingSummary/BuildingConstruction/ConditionedFloorArea"))
  nbeds = Float(XMLHelper.get_value(rated_building, "BuildingDetails/BuildingSummary/BuildingConstruction/NumberofBedrooms"))
  
  msgs, has_error = verify_user_inputs_building(rated_building, msgs, has_error, cfa, nbeds)
  msgs, has_error = verify_user_inputs_mech_vent(rated_building, msgs, has_error)
  msgs, has_error = verify_user_inputs_appliances(rated_building, ref_building, msgs, has_error, nbeds)
  
  verification_log = File.join(resultsdir, "verification.log")
  File.write(verification_log, msgs.join("\n"))
  
  if has_error
    fail "User input verification requirements failed. See #{verification_log} for details."
  end
  
  return cfa, nbeds
end

def verify_user_inputs_building(rated_building, msgs, has_error, cfa, nbeds)

  rated_construction = rated_building.elements["BuildingDetails/BuildingSummary/BuildingConstruction"]
  rated_enclosure = rated_building.elements["BuildingDetails/Enclosure"]

  # Number of bedrooms | <= (CFA-120) / 70 | Error
  if nbeds > (cfa - 120.0) / 70.0
    msgs << "ERROR: Number of bedrooms (#{nbeds}) is not within limits."
    has_error = true
  end
  
  # Stories above grade | 1 <= SAG < =4 | Warning
  nstories_ag = Integer(XMLHelper.get_value(rated_construction, "NumberofConditionedFloorsAboveGrade"))
  if nstories_ag < 1 or nstories_ag > 4
    msgs << "WARNING: Stories above grade (#{nstories_ag}) is not within limits."
  end
  
  # Average ceiling height | 7 <= (Volume / CFA) <= 15 | Warning
  cvolume = Float(XMLHelper.get_value(rated_construction, "ConditionedBuildingVolume"))
  avg_ceil_height = cvolume / cfa
  if avg_ceil_height < 7 or avg_ceil_height > 15
    msgs << "WARNING: Average ceiling height (#{avg_ceil_height.round(2)}) is not within limits."
  end
  
  rated_enclosure.elements.each("Foundations/Foundation") do |foundation|
    
    foundation_type = nil
    is_conditioned = false
    if not foundation.elements["FoundationType/Basement"].nil?
      foundation_type = "Basement"
      if not foundation.elements["FoundationType/Basement[Conditioned='true']"].nil?
        is_conditioned = true
      end
    elsif not foundation.elements["FoundationType/Crawlspace"].nil?
      foundation_type = "Crawlspace"
    elsif not foundation.elements["FoundationType/SlabOnGrade"].nil?
      foundation_type = "SlabOnGrade"
    elsif not foundation.elements["FoundationType/Ambient"].nil?
      foundation_type = "Ambient"
    else
      fail "Unexpected foundation type."
    end
    
    # Below grade slab floors | => 1 below grade wall | Warning
    num_bg_slabs = 0
    num_bg_walls = 0
    foundation.elements.each("Slab") do |foundation_slab|
      if Float(XMLHelper.get_value(foundation_slab, "DepthBelowGrade")) > 0
        num_bg_slabs += 1
      end
    end
    foundation.elements.each("FoundationWall") do |foundation_wall|
      if Float(XMLHelper.get_value(foundation_wall, "BelowGradeDepth")) > 0
        num_bg_walls += 1
      end
    end
    if num_bg_slabs > 0 and num_bg_walls < 1
      msgs << "WARNING: Has below grade slab floors but number of below grade walls (#{num_bg_walls}) is not within limits."
    end
    
    # Below grade walls | => 1 below grade slab floor | Warning
    if num_bg_walls > 0 and num_bg_slabs < 1
      msgs << "WARNING: Has below grade walls but number of below grade slab floors (#{num_bg_slabs}) is not within limits."
    end
    
    if foundation_type != "Ambient"
      # Foundation perimeter (ft) | 1 <= perimeter <= (EFA^0.5 * 7) | Warning
      foundation_perim = Float(XMLHelper.get_value(foundation, "Slab/ExposedPerimeter"))
      foundation_efa = Float(XMLHelper.get_value(foundation, "Slab/Area"))
      if foundation_perim < 1 or foundation_perim > (foundation_efa**0.5 * 7.0)
        msgs << "WARNING: #{foundation_type} perimeter (#{foundation_perim.round(2)} ft) is not within limits."
      end
    end
    
    if foundation_type == "Basement" or foundation_type == "Crawlspace"
    
      # Foundation wall height (ft) | 0 < height <= 20 | Warning
      foundation.elements.each("FoundationWall") do |foundation_wall|
        foundation_wall_height = Float(XMLHelper.get_value(foundation_wall, "Height"))
        if foundation_wall_height <= 0 or foundation_wall_height > 20
          msgs << "WARNING: Foundation wall height (#{foundation_wall_height.round(2)} ft) is not within limits."
        end
      end
      
      if foundation_type == "Basement"
        foundation.elements.each("FoundationWall") do |foundation_wall|
          # Basement wall depth (ft) | 2 <= depth <= (wall height – 0.5) | Warning
          basement_wall_depth = Float(XMLHelper.get_value(foundation_wall, "BelowGradeDepth"))
          foundation_wall_height = Float(XMLHelper.get_value(foundation_wall, "Height"))
          if basement_wall_depth < 2 or basement_wall_depth > (foundation_wall_height - 0.5)
            msgs << "WARNING: Basement wall depth (#{basement_wall_depth.round(2)} ft) is not within limits."
          end
        end
      end
      
      if not (foundation_type == "Basement" and is_conditioned)
        # Uncond. foundation space | => 1 floor above foundation space | Error
        floors = 0
        foundation.elements.each("FrameFloor") do |floor|
          floors += 1
        end
        if floors < 1
          msgs << "ERROR: Uncond. foundation space floors above is not within limits."
          has_error = true
        end
      end
      
    end
  end
  
  # TODO Enclosure floor area | <= enclosure ceiling area | Warning
  
  # TODO Enclosure floor area | <= conditioned floor area | Error
  
  # TODO Enclosure gross wall area | 27 <= (EGWA / (CFA*NCS)^0.5) <= 105 | Warning
  
  # Above grade gross wall area | >= door area + window area | Error
  ag_gross_wall_area = 0.0
  rated_enclosure.elements.each("Walls/Wall") do |wall|
    ag_gross_wall_area += Float(XMLHelper.get_value(wall, "Area"))
  end
  rated_enclosure.elements.each("AtticAndRoof/Attics/Attic/Walls/Wall") do |wall|
    ag_gross_wall_area += Float(XMLHelper.get_value(wall, "Area"))
  end
  door_area = 0.0
  rated_enclosure.elements.each("Doors/Door") do |door|
    door_area += Float(XMLHelper.get_value(door, "Area"))
  end
  window_area = 0.0
  rated_enclosure.elements.each("Windows/Window") do |window|
    window_area += Float(XMLHelper.get_value(window, "Area"))
  end
  if ag_gross_wall_area < door_area + window_area
    msgs << "ERROR: Above grade gross wall area (#{ag_gross_wall_area.round(2)} ft^2) is not within limits."
    has_error = true
  end
  
  # TODO Rating date | <= current date | Error
  
  return msgs, has_error
end

def verify_user_inputs_mech_vent(rated_building, msgs, has_error)

  # Gather inputs
  mv = rated_building.elements["BuildingDetails/Systems/MechanicalVentilation/VentilationFans/VentilationFan[UsedForWholeBuildingVentilation='true']"]
  return msgs, has_error if mv.nil?
  
  mv_type = XMLHelper.get_value(mv, "FanType")
  mv_fan_power = Float(XMLHelper.get_value(mv, "FanPower"))
  mv_flow_rate = Float(XMLHelper.get_value(mv, "RatedFlowRate"))
  mv_hours = Float(XMLHelper.get_value(mv, "HoursInOperation"))
  
  mv_w_cfm = mv_fan_power / mv_flow_rate * mv_hours / 24.0
  mv_cfm = mv_flow_rate * mv_hours / 24.0
  
  if mv_type == 'exhaust only'
    # Exhaust | => 0.12 W/cfm | n/a | => 0.12 W/cfm
    if mv_w_cfm < 0.12
      msgs << "WARNING: Mechanical ventilation (#{mv_w_cfm.round(3)} W/cfm) is not within limits."
    end
    
  elsif mv_type == 'supply only'
    # Supply | n/a | => 0.12 W/cfm | => 0.12 W/cfm
    if mv_w_cfm < 0.12
      msgs << "WARNING: Mechanical ventilation (#{mv_w_cfm.round(3)} W/cfm) is not within limits."
    end
    
  elsif mv_type == 'balanced'
    # Balanced | => 0.12 W/cfm | => 0.12 W/cfm | => 0.24 W/cfm
    if mv_w_cfm < 0.24 # FIXME: need to adjust for # fans?
      msgs << "WARNING: Mechanical ventilation (#{mv_w_cfm.round(3)} W/cfm) is not within limits."
    end
    
  elsif mv_type == 'energy recovery ventilator'
    # ERV | n/a | n/a | => 0.48 W/cfm
    if mv_w_cfm < 0.48 # FIXME: need to adjust for # fans?
      msgs << "WARNING: Mechanical ventilation (#{mv_w_cfm.round(3)} W/cfm) is not within limits."
    end
    
  elsif mv_type == 'central fan integrated supply'
    # TODO CFIS PSC motor (SEER <= 13; AFUE <= 90%) | => 0.48 W/cfm
    # TODO CFIS ECM motor (SEER => 15; AFUE => 92%) | => 0.36 W/cfm
  
  end
  
  # TODO For the purposes of calculating the impacts of whole-house ventilation systems 
  # in the Rated Home, accredited software tools shall ensure that the time-averaged 
  # ventilation rate is equal to or greater than the minimum allowed by Section 4.2, 
  # ANSI/RESNET 301-2014, regardless of the user’s entry
  # For example, if the whole house ventilation fan requirement is 50 cfm continuous 
  # and the whole house ventilation system is intermittent with a 33% duty cycle 
  # (typical of a fan cycler system), the ventilation rate during the 33% duty cycle 
  # must be 150 cfm for the Rated Home calculations. Software users can be warned of 
  # this requirement (and its implementation in the software) but shall not be allowed 
  # to override it.

  return msgs, has_error
end

def verify_user_inputs_appliances(rated_building, ref_building, msgs, has_error, nbeds)

  rated_appliances = rated_building.elements["BuildingDetails/Appliances"]
  rated_waterheating = rated_building.elements["BuildingDetails/Systems/WaterHeating"]
  ref_appliances = ref_building.elements["BuildingDetails/Appliances"]
  ref_waterheating = ref_building.elements["BuildingDetails/Systems/WaterHeating"]
  
  # Gather inputs
  cw_kwh = Float(XMLHelper.get_value(rated_appliances, "ClothesWasher/extension/AnnualkWh"))
  cf_fuel = XMLHelper.get_value(rated_appliances, "ClothesDryer/FuelType")
  cd_kwh = Float(XMLHelper.get_value(rated_appliances, "ClothesDryer/extension/AnnualkWh"))
  cd_therm = Float(XMLHelper.get_value(rated_appliances, "ClothesDryer/extension/AnnualTherm"))
  dw_gpd = Float(XMLHelper.get_value(rated_appliances, "Dishwasher/extension/HotWaterGPD"))
  cw_gpd = Float(XMLHelper.get_value(rated_appliances, "ClothesWasher/extension/HotWaterGPD"))
  w_gpd = Float(XMLHelper.get_value(rated_waterheating, "HotWaterDistribution/extension/MixedWaterGPD"))
  f_gpd = Float(XMLHelper.get_value(rated_waterheating, "WaterFixture[WaterFixtureType='shower head']/extension/MixedWaterGPD"))
  f_mix = Float(XMLHelper.get_value(rated_waterheating, "WaterHeatingSystem/extension/Fmix"))
  ref_dw_gpd = Float(XMLHelper.get_value(ref_appliances, "Dishwasher/extension/HotWaterGPD"))
  ref_cw_gpd = Float(XMLHelper.get_value(ref_appliances, "ClothesWasher/extension/HotWaterGPD"))
  ref_w_gpd = Float(XMLHelper.get_value(ref_waterheating, "HotWaterDistribution/extension/MixedWaterGPD"))
  ref_f_gpd = Float(XMLHelper.get_value(ref_waterheating, "WaterFixture[WaterFixtureType='shower head']/extension/MixedWaterGPD"))
  ref_f_mix = Float(XMLHelper.get_value(ref_waterheating, "WaterHeatingSystem/extension/Fmix"))

  # Clothes washers (kWh/y) | (21*Nbr + 73) > CWkWh > (4.7*Nbr + 16.4) | Warning
  if cw_kwh <= (4.7 * nbeds + 16.4) or cw_kwh >= (21.0 * nbeds + 73.0)
    msgs << "WARNING: Clothes washers (#{cd_kwh.round(2)} kWh/y) is not within limits."
  end
  
  if cf_fuel == "electricity"
    # Electric dryers (kWh/y) | (163*Nbr + 577) > eCDkWh > (55*Nbr + 194) | Warning
    if cd_kwh <= (55.0 * nbeds + 194.0) or cd_kwh >= (163.0 * nbeds + 577.0)
      msgs << "WARNING: Electric dryers (#{cd_kwh.round(2)} kWh/y) is not within limits."
    end
    
  else
    # Gas dryers (therms/y) | (5.9*Nbr + 20.6) > gCDtherms > (2.0*Nbr + 6.9) | Warning
    if cd_therm <= (2.0 * nbeds + 6.9) or cd_therm >= (5.9 * nbeds + 20.6)
      msgs << "WARNING: Gas dryers (#{cd_therm.round(2)} therms/y) is not within limits."
    end
    
    # Gas dryers (kWh/y) | (12.9*Nbr + 45.5) > gCDkWh > (4.3*Nbr + 15.3) | Warning
    if cd_kwh <= (4.3 * nbeds + 15.3) or cd_kwh >= (12.9 * nbeds + 45.5)
      msgs << "WARNING: Gas dryers (#{cd_kwh.round(2)} kWh/y) is not within limits."
    end
  end
  
  # Hot water savings (gpd) | HWgpdSave < (0.59*Nbr +2.1) | Warning
  ref_hw_gpd = ref_dw_gpd + ref_cw_gpd + ref_f_mix * (ref_f_gpd + ref_w_gpd)
  hw_gpd = dw_gpd + cw_gpd + f_mix * (f_gpd + w_gpd)
  hw_gpd_save = ref_hw_gpd - hw_gpd
  msgs << "DEBUG: ref_dw_gpd #{ref_dw_gpd} ref_cw_gpd #{ref_cw_gpd} ref_f_gpd #{ref_f_mix * ref_f_gpd} ref_w_gpd #{ref_f_mix * ref_w_gpd}"
  msgs << "DEBUG: dw_gpd #{dw_gpd} cw_gpd #{cw_gpd} f_gpd #{f_mix * f_gpd} w_gpd #{f_mix * w_gpd}"
  if hw_gpd_save >= (0.59 * nbeds + 2.1)
    msgs << "WARNING: Hot water savings (#{hw_gpd_save.round(2)} gpd) is not within limits."
  end

  return msgs, has_error
end

def calculate_eri(sim_outputs, resultsdir)

  rated_output = sim_outputs[Constants.CalcTypeERIRatedHome]
  ref_output = sim_outputs[Constants.CalcTypeERIReferenceHome]
  rated_hpxml_doc = REXML::Document.new(File.read(rated_output[:hpxml]))
  ref_hpxml_doc = REXML::Document.new(File.read(ref_output[:hpxml]))
  
  results = {}
  
  # Verify user inputs before producing ERI
  results[:cfa], results[:nbr] = verify_user_inputs(rated_hpxml_doc, ref_hpxml_doc, resultsdir)
  
  # REUL = Reference Home End Use Loads (for heating, cooling or hot water) as computed using an Approved 
  # Software Rating Tool.
  # Heating/Cooling loads include effect of DSE, so we remove the effect below.
  dse_heat, dse_cool = get_dse_heat_cool(ref_hpxml_doc)
  results[:reul_heat] = ref_output[:loadHeating] * dse_heat
  results[:reul_cool] = ref_output[:loadCooling] * dse_cool
  results[:reul_dhw] = ref_output[:loadHotWater]
  
  # XEUL = Rated Home End Use Loads (for heating, cooling or hot water) as computed using an Approved 
  # Software Rating Tool.
  results[:xeul_heat] = 0 # TODO
  results[:xeul_cool] = 0 # TODO
  results[:xeul_dhw] = 0 # TODO
  
  # Table 4.2.1(1) Coefficients ‘a’ and ‘b’
  results[:coeff_cool_a] = 3.8090
  results[:coeff_cool_b] = 0.0
  results[:coeff_heat_a] = nil
  results[:coeff_heat_b] = nil
  results[:coeff_dhw_a] = nil
  results[:coeff_dhw_b] = nil
  heat_fuel = get_heating_fuel(rated_hpxml_doc)
  if heat_fuel == 'electricity'
    results[:coeff_heat_a] = 2.2561
    results[:coeff_heat_b] = 0.0
  elsif ['natural gas','fuel oil','propane'].include? heat_fuel
    results[:coeff_heat_a] = 1.0943
    results[:coeff_heat_b] = 0.4030
  end
  dwh_fuel = get_dhw_fuel(rated_hpxml_doc)
  if dwh_fuel == 'electricity'
    results[:coeff_dhw_a] = 0.9200
    results[:coeff_dhw_b] = 0.0
  elsif ['natural gas','fuel oil','propane'].include? dwh_fuel
    results[:coeff_dhw_a] = 1.1877
    results[:coeff_dhw_b] = 1.0130
  end
  if results[:coeff_heat_a].nil? or results[:coeff_heat_b].nil?
    fail "ERROR: Could not identify EEC coefficients for heating system."
  end
  if results[:coeff_dhw_a].nil? or results[:coeff_dhw_b].nil?
    fail "ERROR: Could not identify EEC coefficients for water heating system."
  end
  
  # EEC_x = Equipment Efficiency Coefficient for the Rated Home’s equipment, such that EEC_x equals the 
  # energy consumption per unit load in like units as the load, and as derived from the Manufacturer’s 
  # Equipment Performance Rating (MEPR) such that EEC_x equals 1.0 / MEPR for AFUE, COP or EF ratings, or 
  # such that EEC_x equals 3.413 / MEPR for HSPF, EER or SEER ratings.
  results[:eec_x_heat] = get_eec_heat(rated_hpxml_doc)
  results[:eec_x_cool] = get_eec_cool(rated_hpxml_doc)
  results[:eec_x_dhw] = get_eec_dhw(rated_hpxml_doc)
  
  # EEC_r = Equipment Efficiency Coefficient for the Reference Home’s equipment, such that EEC_r equals the 
  # energy consumption per unit load in like units as the load, and as derived from the Manufacturer’s 
  # Equipment Performance Rating (MEPR) such that EEC_r equals 1.0 / MEPR for AFUE, COP or EF ratings, or 
  # such that EEC_r equals 3.413 / MEPR for HSPF, EER or SEER ratings
  results[:eec_r_heat] = get_eec_heat(ref_hpxml_doc)
  results[:eec_r_cool] = get_eec_cool(ref_hpxml_doc)
  results[:eec_r_dhw] = get_eec_dhw(ref_hpxml_doc)
  
  # EC_x = estimated Energy Consumption for the Rated Home’s end uses (for heating, including Auxiliary 
  # Electric Consumption, cooling or hot water) as computed using an Approved Software Rating Tool.
  results[:ec_x_heat] = rated_output[:elecHeating] + rated_output[:fuelHeating]
  results[:ec_x_cool] = rated_output[:elecCooling]
  results[:ec_x_dhw] = (rated_output[:elecHotWater] + rated_output[:fuelHotWater]) * dhw_adjustment(rated_hpxml_doc) + rated_output[:elecRecircPump]
  
  # EC_r = estimated Energy Consumption for the Reference Home’s end uses (for heating, including Auxiliary 
  # Electric Consumption, cooling or hot water) as computed using an Approved Software Rating Tool.
  results[:ec_r_heat] = ref_output[:elecHeating] + ref_output[:fuelHeating]
  results[:ec_r_cool] = ref_output[:elecCooling]
  results[:ec_r_dhw] = ref_output[:elecHotWater] + ref_output[:fuelHotWater]
  
  # DSE_r = REUL/EC_r * EEC_r
  # For simplified system performance methods, DSE_r equals 0.80 for heating and cooling systems and 1.00 
  # for hot water systems [see Table 4.2.2(1)]. However, for detailed modeling of heating and cooling systems,
  # DSE_r may be less than 0.80 as a result of part load performance degradation, coil air flow degradation, 
  # improper system charge and auxiliary resistance heating for heat pumps. Except as otherwise provided by 
  # these Standards, where detailed systems modeling is employed, it must be applied equally to both the 
  # Reference and the Rated Homes.
  results[:dse_r_heat] = results[:reul_heat] / results[:ec_r_heat] * results[:eec_r_heat]
  results[:dse_r_cool] = results[:reul_cool] / results[:ec_r_cool] * results[:eec_r_cool]
  results[:dse_r_dhw] = results[:reul_dhw] / results[:ec_r_dhw] * results[:eec_r_dhw]
  
  # nEC_x = (a* EEC_x – b)*(EC_x * EC_r * DSE_r) / (EEC_x * REUL) (Eq 4.1-1a)
  results[:nec_x_heat] = 0
  results[:nec_x_cool] = 0
  results[:nec_x_dhw] = 0
  if results[:eec_x_heat] * results[:reul_heat] > 0
    results[:nec_x_heat] = (results[:coeff_heat_a] * results[:eec_x_heat] - results[:coeff_heat_b])*(results[:ec_x_heat] * results[:ec_r_heat] * results[:dse_r_heat]) / (results[:eec_x_heat] * results[:reul_heat])
  end
  if results[:eec_x_cool] * results[:reul_cool] > 0
    results[:nec_x_cool] = (results[:coeff_cool_a] * results[:eec_x_cool] - results[:coeff_cool_b])*(results[:ec_x_cool] * results[:ec_r_cool] * results[:dse_r_cool]) / (results[:eec_x_cool] * results[:reul_cool])
  end
  if results[:eec_x_dhw] * results[:reul_dhw] > 0
    results[:nec_x_dhw] = (results[:coeff_dhw_a] * results[:eec_x_dhw] - results[:coeff_dhw_b])*(results[:ec_x_dhw] * results[:ec_r_dhw] * results[:dse_r_dhw]) / (results[:eec_x_dhw] * results[:reul_dhw])
  end
  
  # The normalized Modified End Use Loads (nMEUL) for space heating and cooling and domestic hot water use 
  # shall each be determined in accordance with Equation 4.1-1:
  # nMEUL = REUL * (nEC_x / EC_r) (Eq 4.1-1)
  results[:nmeul_heat] = 0
  results[:nmeul_cool] = 0
  results[:nmeul_dhw] = 0
  if results[:ec_r_heat] > 0
    results[:nmeul_heat] = results[:reul_heat] * (results[:nec_x_heat] / results[:ec_r_heat])
  end
  if results[:ec_r_cool] > 0
    results[:nmeul_cool] = results[:reul_cool] * (results[:nec_x_cool] / results[:ec_r_cool])
  end
  if results[:ec_r_dhw] > 0
    results[:nmeul_dhw] = results[:reul_dhw] * (results[:nec_x_dhw] / results[:ec_r_dhw])
  end
      
  # TEU = Total energy use of the Rated Home including all rated and non-rated energy features where all 
  # fossil fuel site energy uses (Btufossil) are converted to equivalent electric energy use (kWheq) in 
  # accordance with Equation 4.1-3.
  # kWheq = (Btufossil * 0.40) / 3412 (Eq 4.1-3)
  results[:teu] = rated_output[:elecTotal] + 0.4 * rated_output[:fuelTotal]
  
  # OPP = On-Site Power Production as defined by Section 5.1.1.4 of this Standard.
  results[:opp] = rated_output[:elecPV]
  
  # PEfrac = (TEU - OPP) / TEU
  results[:pefrac] = 1.0
  if results[:teu] > 0
    results[:pefrac] = (results[:teu] - results[:opp]) / results[:teu]
  end
  
  # EULLA = The Rated Home end use loads for lighting, appliances and MELs as defined by Section 4.2.2.5.2, 
  # converted to MBtu/y, where MBtu/y = (kWh/y)/293 or (therms/y)/10, as appropriate.
  results[:eul_la] = (rated_output[:elecIntLighting] + rated_output[:elecExtLighting] + 
                      rated_output[:elecAppliances] + rated_output[:fuelAppliances])
  
  # REULLA = The Reference Home end use loads for lighting, appliances and MELs as defined by Section 4.2.2.5.1, 
  # converted to MBtu/y, where MBtu/y = (kWh/y)/293 or (therms/y)/10, as appropriate.
  results[:reul_la] = (ref_output[:elecIntLighting] + ref_output[:elecExtLighting] + 
                       ref_output[:elecAppliances] + ref_output[:fuelAppliances])
  
  # TRL = REULHEAT + REULCOOL + REULHW + REULLA (MBtu/y).
  results[:trl] = results[:reul_heat] + results[:reul_cool] + results[:reul_dhw] + results[:reul_la]

  # TnML = nMEULHEAT + nMEULCOOL + nMEULHW + EULLA (MBtu/y).  
  results[:tnml] = results[:nmeul_heat] + results[:nmeul_cool] + results[:nmeul_dhw] + results[:eul_la]
  
  # The HERS Index shall be determined in accordance with Equation 4.1-2:
  # HERS Index = PEfrac * (TnML / TRL) * 100
  results[:hers_index] = results[:pefrac] * 100 * results[:tnml] / results[:trl]
  results[:hers_index] = results[:hers_index]

  return results
end

def write_results_annual_output(out_csv, sim_output)
  results_out = {
                 "Electricity, Total (MBtu)"=>sim_output[:elecTotal],
                 "Electricity, Net (MBtu)"=>sim_output[:elecTotal]-sim_output[:elecPV],
                 "Natural Gas, Total (MBtu)"=>sim_output[:ngTotal],
                 "Other Fuels, Total (MBtu)"=>sim_output[:otherTotal],
                 ""=>"", # line break
                 "Electricity, Heating (MBtu)"=>sim_output[:elecHeating],
                 "Electricity, Cooling (MBtu)"=>sim_output[:elecCooling],
                 "Electricity, Fans/Pumps (MBtu)"=>sim_output[:elecFans]+sim_output[:elecPumps],
                 "Electricity, Hot Water (MBtu)"=>sim_output[:elecHotWater]+sim_output[:elecRecircPump],
                 "Electricity, Lighting (MBtu)"=>sim_output[:elecIntLighting]+sim_output[:elecExtLighting],
                 "Electricity, Mech Vent (MBtu)"=>sim_output[:elecMechVent],
                 "Electricity, Refrigerator (MBtu)"=>sim_output[:elecFridge],
                 "Electricity, Dishwasher (MBtu)"=>sim_output[:elecDishwasher],
                 "Electricity, Clothes Washer (MBtu)"=>sim_output[:elecClothesWasher],
                 "Electricity, Clothes Dryer (MBtu)"=>sim_output[:elecClothesDryer],
                 "Electricity, Range/Oven (MBtu)"=>sim_output[:elecRangeOven],
                 "Electricity, Ceiling Fan (MBtu)"=>sim_output[:elecCeilingFan],
                 "Electricity, Plug Loads (MBtu)"=>sim_output[:elecMELs],
                 "Electricity, PV (MBtu)"=>sim_output[:elecPV],
                 "Natural Gas, Heating (MBtu)"=>sim_output[:ngHeating],
                 "Natural Gas, Hot Water (MBtu)"=>sim_output[:ngHotWater],
                 "Natural Gas, Clothes Dryer (MBtu)"=>sim_output[:ngClothesDryer],
                 "Natural Gas, Range/Oven (MBtu)"=>sim_output[:ngRangeOven],
                 "Other Fuels, Heating (MBtu)"=>sim_output[:otherHeating],
                 "Other Fuels, Hot Water (MBtu)"=>sim_output[:otherHotWater],
                 "Other Fuels, Clothes Dryer (MBtu)"=>sim_output[:otherClothesDryer],
                 "Other Fuels, Range/Oven (MBtu)"=>sim_output[:otherRangeOven],
                }
  CSV.open(out_csv, "wb") {|csv| results_out.to_a.each {|elem| csv << elem} }
end

def write_results(results, resultsdir, sim_outputs)

  # Results file
  results_csv = File.join(resultsdir, "ERI_Results.csv")
  results_out = {
                 "HERS Index"=>results[:hers_index].round(2),
                 "REUL Heating (MBtu)"=>results[:reul_heat].round(2),
                 "REUL Cooling (MBtu)"=>results[:reul_cool].round(2),
                 "REUL Hot Water (MBtu)"=>results[:reul_dhw].round(2),
                 "EC_r Heating (MBtu)"=>results[:ec_r_heat].round(2),
                 "EC_r Cooling (MBtu)"=>results[:ec_r_cool].round(2),
                 "EC_r Hot Water (MBtu)"=>results[:ec_r_dhw].round(2),
                 #"XEUL Heating (MBtu)"=>results[:xeul_heat].round(2),
                 #"XEUL Cooling (MBtu)"=>results[:xeul_cool].round(2),
                 #"XEUL Hot Water (MBtu)"=>results[:xeul_dhw].round(2),
                 "EC_x Heating (MBtu)"=>results[:ec_x_heat].round(2),
                 "EC_x Cooling (MBtu)"=>results[:ec_x_cool].round(2),
                 "EC_x Hot Water (MBtu)"=>results[:ec_x_dhw].round(2),
                 "EC_x L&A (MBtu)"=>results[:eul_la].round(2),
                 # TODO:
                 # Heating Fuel
                 # Heating MEPR
                 # Cooling Fuel
                 # Cooling MEPR
                 # Hot Water Fuel
                 # Hot Water MEPR
                }
  CSV.open(results_csv, "wb") {|csv| results_out.to_a.each {|elem| csv << elem} }
  
  # Worksheet file
  worksheet_csv = File.join(resultsdir, "ERI_Worksheet.csv")
  ref_output = sim_outputs[Constants.CalcTypeERIReferenceHome]
  worksheet_out = {
                   "Coeff Heating a"=>results[:coeff_heat_a].round(4),
                   "Coeff Heating b"=>results[:coeff_heat_b].round(4),
                   "Coeff Cooling a"=>results[:coeff_cool_a].round(4),
                   "Coeff Cooling b"=>results[:coeff_cool_b].round(4),
                   "Coeff Hot Water a"=>results[:coeff_dhw_a].round(4),
                   "Coeff Hot Water b"=>results[:coeff_dhw_b].round(4),
                   "DSE_r Heating"=>results[:dse_r_heat].round(4),
                   "DSE_r Cooling"=>results[:dse_r_cool].round(4),
                   "DSE_r Hot Water"=>results[:dse_r_dhw].round(4),
                   "EEC_x Heating"=>results[:eec_x_heat].round(4),
                   "EEC_x Cooling"=>results[:eec_x_cool].round(4),
                   "EEC_x Hot Water"=>results[:eec_x_dhw].round(4),
                   "EEC_r Heating"=>results[:eec_r_heat].round(4),
                   "EEC_r Cooling"=>results[:eec_r_cool].round(4),
                   "EEC_r Hot Water"=>results[:eec_r_dhw].round(4),
                   "nEC_x Heating"=>results[:nec_x_heat].round(4),
                   "nEC_x Cooling"=>results[:nec_x_cool].round(4),
                   "nEC_x Hot Water"=>results[:nec_x_dhw].round(4),
                   "nMEUL Heating"=>results[:nmeul_heat].round(4),
                   "nMEUL Cooling"=>results[:nmeul_cool].round(4),
                   "nMEUL Hot Water"=>results[:nmeul_dhw].round(4),
                   "Total Loads TnML"=>results[:tnml].round(4),
                   "Total Loads TRL"=>results[:trl].round(4),
                   "HERS Index"=>results[:hers_index].round(2),
                   ""=>"", # line break
                   "Home CFA"=>results[:cfa],
                   "Home Nbr"=>results[:nbr],
                   "L&A resMELs"=>ref_output[:elecMELs].round(2),
                   "L&A intLgt"=>ref_output[:elecIntLighting].round(2),
                   "L&A extLgt"=>ref_output[:elecExtLighting].round(2),
                   "L&A Fridg"=>ref_output[:elecFridge].round(2),
                   "L&A TVs"=>0.round(2), # FIXME
                   "L&A R/O"=>(ref_output[:elecRangeOven]+ref_output[:fuelRangeOven]).round(2),
                   "L&A cDryer"=>(ref_output[:elecClothesDryer]+ref_output[:fuelClothesDryer]).round(2),
                   "L&A dWash"=>ref_output[:elecDishwasher].round(2),
                   "L&A cWash"=>ref_output[:elecClothesWasher].round(2),
                   "L&A total"=>results[:reul_la].round(2),
                  }
  CSV.open(worksheet_csv, "wb") {|csv| worksheet_out.to_a.each {|elem| csv << elem} }
  
  # Summary energy results
  rated_annual_csv = File.join(resultsdir, "HERSRatedHome.csv")
  rated_output = sim_outputs[Constants.CalcTypeERIRatedHome]
  write_results_annual_output(rated_annual_csv, rated_output)
  
  ref_annual_csv = File.join(resultsdir, "HERSReferenceHome.csv")
  ref_output = sim_outputs[Constants.CalcTypeERIReferenceHome]
  write_results_annual_output(ref_annual_csv, ref_output)
  
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename(__FILE__)} -x building.xml\n e.g., #{File.basename(__FILE__)} -x sample_files/valid.xml\n"

  opts.on('-x', '--xml <FILE>', 'HPXML file') do |t|
    options[:hpxml] = t
  end

  options[:debug] = false
  opts.on('-d', '--debug') do |t|
    options[:debug] = true
  end
  
  opts.on_tail('-h', '--help', 'Display help') do
    puts opts
    exit
  end

end.parse!

if not options[:hpxml]
  fail "ERROR: HPXML argument is required. Call #{File.basename(__FILE__)} -h for usage."
end

unless (Pathname.new options[:hpxml]).absolute?
  options[:hpxml] = File.expand_path(File.join(File.dirname(__FILE__), options[:hpxml]))
end 
unless File.exists?(options[:hpxml]) and options[:hpxml].downcase.end_with? ".xml"
  fail "ERROR: '#{options[:hpxml]}' does not exist or is not an .xml file."
end

# Check for correct versions of OS
os_version = "2.5.0"
if OpenStudio.openStudioVersion != os_version
  fail "ERROR: OpenStudio version #{os_version} is required."
end

# Create results dir
resultsdir = File.join(basedir, "results")
recreate_path(resultsdir)

# Run simulations
sim_outputs = {}
puts "HPXML: #{options[:hpxml]}"

Parallel.map(designs, in_threads: designs.size) do |design|
  # Use print instead of puts here (see https://stackoverflow.com/a/5044669)
  
  print "[#{design}] Running workflow...\n"
  osw_path, output_hpxml_path = create_osw(design, basedir, resultsdir, options)
  sql_path = run_osw(osw_path)
  
  print "[#{design}] Gathering results...\n"
  sim_outputs[design] = parse_sql(design, sql_path, output_hpxml_path)
  
  print "[#{design}] Done.\n"
end

# Calculate and write results
puts "Calculating ERI..."
results = calculate_eri(sim_outputs, resultsdir)

puts "Writing output files..."
write_results(results, resultsdir, sim_outputs)

puts "Output files written to '#{File.basename(resultsdir)}' directory."
puts "Completed in #{(Time.now - start_time).round(1)} seconds."