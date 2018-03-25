require "#{File.dirname(__FILE__)}/constants"
require "#{File.dirname(__FILE__)}/geometry"
require "#{File.dirname(__FILE__)}/util"
require "#{File.dirname(__FILE__)}/unit_conversions"
require "#{File.dirname(__FILE__)}/psychrometrics"
require "#{File.dirname(__FILE__)}/weather"

class HVAC

    def self.apply_central_ac_1speed(model, unit, runner, seer, eers, shrs,
                                     fan_power_rated, fan_power_installed,
                                     crankcase_capacity, crankcase_temp,
                                     eer_capacity_derates, capacity, dse)
    
      num_speeds = 1

      # Performance curves
      # NOTE: These coefficients are in IP UNITS
      cOOL_CAP_FT_SPEC = [[3.670270705, -0.098652414, 0.000955906, 0.006552414, -0.0000156, -0.000131877]]
      cOOL_EIR_FT_SPEC = [[-3.302695861, 0.137871531, -0.001056996, -0.012573945, 0.000214638, -0.000145054]]
      cOOL_CAP_FFLOW_SPEC = [[0.718605468, 0.410099989, -0.128705457]]
      cOOL_EIR_FFLOW_SPEC = [[1.32299905, -0.477711207, 0.154712157]]
      
      static = UnitConversions.convert(0.5,"inH2O","Pa") # Pascal

      capacity_ratios = [1.0]
      fan_speed_ratios = [1.0]
      
      # Cooling Coil
      rated_airflow_rate = 386.1 # cfm
      cfms_ton_rated = calc_cfms_ton_rated(rated_airflow_rate, fan_speed_ratios, capacity_ratios)
      cooling_eirs = calc_cooling_eirs(num_speeds, eers, fan_power_rated)
      shrs_rated_gross = calc_shrs_rated_gross(num_speeds, shrs, fan_power_rated, cfms_ton_rated)
      cOOL_CLOSS_FPLR_SPEC = [calc_plr_coefficients_cooling(num_speeds, seer)]
    
      obj_name = Constants.ObjectNameCentralAirConditioner(unit.name.to_s)
      
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
    
        # Remove existing equipment
        htg_coil, _perf = remove_existing_hvac_equipment(model, runner, Constants.ObjectNameCentralAirConditioner, control_zone, false, unit)

        # _processCurvesDXCooling
        
        clg_coil_stage_data = calc_coil_stage_data_cooling(model, capacity, num_speeds, cooling_eirs, shrs_rated_gross, cOOL_CAP_FT_SPEC, cOOL_EIR_FT_SPEC, cOOL_CLOSS_FPLR_SPEC, cOOL_CAP_FFLOW_SPEC, cOOL_EIR_FFLOW_SPEC, dse)

        # _processSystemCoolingCoil
        
        clg_coil = OpenStudio::Model::CoilCoolingDXSingleSpeed.new(model, model.alwaysOnDiscreteSchedule, clg_coil_stage_data[0].totalCoolingCapacityFunctionofTemperatureCurve, clg_coil_stage_data[0].totalCoolingCapacityFunctionofFlowFractionCurve, clg_coil_stage_data[0].energyInputRatioFunctionofTemperatureCurve, clg_coil_stage_data[0].energyInputRatioFunctionofFlowFractionCurve, clg_coil_stage_data[0].partLoadFractionCorrelationCurve)
        clg_coil_stage_data[0].remove
        clg_coil.setName(obj_name + " cooling coil")
        if capacity != Constants.SizingAuto
          clg_coil.setRatedTotalCoolingCapacity(UnitConversions.convert(capacity,"Btu/hr","W")) # Used by HVACSizing measure
        end
        clg_coil.setRatedSensibleHeatRatio(shrs_rated_gross[0])
        clg_coil.setRatedCOP(OpenStudio::OptionalDouble.new(dse / cooling_eirs[0]))
        clg_coil.setRatedEvaporatorFanPowerPerVolumeFlowRate(OpenStudio::OptionalDouble.new(fan_power_rated / UnitConversions.convert(1.0,"cfm","m^3/s")))

        clg_coil.setNominalTimeForCondensateRemovalToBegin(OpenStudio::OptionalDouble.new(1000.0))
        clg_coil.setRatioOfInitialMoistureEvaporationRateAndSteadyStateLatentCapacity(OpenStudio::OptionalDouble.new(1.5))
        clg_coil.setMaximumCyclingRate(OpenStudio::OptionalDouble.new(3.0))
        clg_coil.setLatentCapacityTimeConstant(OpenStudio::OptionalDouble.new(45.0))

        clg_coil.setCondenserType("AirCooled")
        clg_coil.setCrankcaseHeaterCapacity(OpenStudio::OptionalDouble.new(UnitConversions.convert(crankcase_capacity,"kW","W")))
        clg_coil.setMaximumOutdoorDryBulbTemperatureForCrankcaseHeaterOperation(OpenStudio::OptionalDouble.new(UnitConversions.convert(crankcase_temp,"F","C")))
          
        # _processSystemFan
        if not htg_coil.nil?
          begin
            fuel_type = HelperMethods.reverse_eplus_fuel_map(htg_coil.fuelType)
          rescue
            fuel_type = Constants.FuelTypeElectric
          end
          obj_name = Constants.ObjectNameFurnaceAndCentralAirConditioner(fuel_type, unit.name.to_s)
        end
        
        fan = OpenStudio::Model::FanOnOff.new(model, model.alwaysOnDiscreteSchedule)
        fan.setName(obj_name + " supply fan")
        fan.setEndUseSubcategory(Constants.EndUseHVACFan)
        fan.setFanEfficiency(dse * calculate_fan_efficiency(static, fan_power_installed))
        fan.setPressureRise(static)
        fan.setMotorEfficiency(dse * 1.0)
        fan.setMotorInAirstreamFraction(1.0) 
      
        # _processSystemAir
              
        air_loop_unitary = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
        air_loop_unitary.setName(obj_name + " unitary system")
        air_loop_unitary.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
        air_loop_unitary.setCoolingCoil(clg_coil)      
        if not htg_coil.nil?
          # Add the existing furnace back in
          air_loop_unitary.setHeatingCoil(htg_coil)
        else
          air_loop_unitary.setSupplyAirFlowRateDuringHeatingOperation(0.0000001) # this is when there is no heating present
        end
        air_loop_unitary.setSupplyFan(fan)
        air_loop_unitary.setFanPlacement("BlowThrough")
        air_loop_unitary.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule)
        air_loop_unitary.setMaximumSupplyAirTemperature(UnitConversions.convert(120.0,"F","C"))
        air_loop_unitary.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(0)    
        
        air_loop = OpenStudio::Model::AirLoopHVAC.new(model)
        air_loop.setName(obj_name + " central air system")
        air_supply_inlet_node = air_loop.supplyInletNode
        air_supply_outlet_node = air_loop.supplyOutletNode
        air_demand_inlet_node = air_loop.demandInletNode
        air_demand_outlet_node = air_loop.demandOutletNode    
        
        air_loop_unitary.addToNode(air_supply_inlet_node)
        
        runner.registerInfo("Added '#{fan.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{clg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        unless htg_coil.nil?
          runner.registerInfo("Added '#{htg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        end
        
        air_loop_unitary.setControllingZoneorThermostatLocation(control_zone)
        
        # _processSystemDemandSideAir
        # Demand Side

        # Supply Air
        zone_splitter = air_loop.zoneSplitter
        zone_splitter.setName(obj_name + " zone splitter")
        
        zone_mixer = air_loop.zoneMixer
        zone_mixer.setName(obj_name + " zone mixer")

        diffuser_living = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
        diffuser_living.setName(obj_name + " #{control_zone.name} direct air")
        air_loop.addBranchForZone(control_zone, diffuser_living.to_StraightComponent)

        air_loop.addBranchForZone(control_zone)
        runner.registerInfo("Added '#{air_loop.name}' to '#{control_zone.name}' of #{unit.name}")

        prioritize_zone_hvac(model, runner, control_zone)
        
        slave_zones.each do |slave_zone|

          # Remove existing equipment
          remove_existing_hvac_equipment(model, runner, Constants.ObjectNameCentralAirConditioner, slave_zone, false, unit)
      
          diffuser_fbsmt = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
          diffuser_fbsmt.setName(obj_name + " #{slave_zone.name} direct air")
          air_loop.addBranchForZone(slave_zone, diffuser_fbsmt.to_StraightComponent)

          air_loop.addBranchForZone(slave_zone)
          runner.registerInfo("Added '#{air_loop.name}' to '#{slave_zone.name}' of #{unit.name}")

          prioritize_zone_hvac(model, runner, slave_zone)
          
        end # slave_zone
      
      end # control_zone
      
      # Store info for HVAC Sizing measure
      unit.setFeature(Constants.SizingInfoHVACCapacityDerateFactorEER, eer_capacity_derates.join(","))
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonCooling, cfms_ton_rated.join(","))
      
      return true
    
    end

    def self.apply_central_ac_2speed(model, unit, runner, seer, eers, shrs,
                                     capacity_ratios, fan_speed_ratios,
                                     fan_power_rated, fan_power_installed,
                                     crankcase_capacity, crankcase_temp,
                                     eer_capacity_derates, capacity, dse)
    
      num_speeds = 2
      
      # Performance curves
      # NOTE: These coefficients are in IP UNITS
      cOOL_CAP_FT_SPEC = [[3.940185508, -0.104723455, 0.001019298, 0.006471171, -0.00000953, -0.000161658],
                          [3.109456535, -0.085520461, 0.000863238, 0.00863049, -0.0000210, -0.000140186]]
      cOOL_EIR_FT_SPEC = [[-3.877526888, 0.164566276, -0.001272755, -0.019956043, 0.000256512, -0.000133539],
                          [-1.990708931, 0.093969249, -0.00073335, -0.009062553, 0.000165099, -0.0000997]]
      cOOL_CAP_FFLOW_SPEC = [[0.65673024, 0.516470835, -0.172887149], 
                             [0.690334551, 0.464383753, -0.154507638]]
      cOOL_EIR_FFLOW_SPEC = [[1.562945114, -0.791859997, 0.230030877], 
                             [1.31565404, -0.482467162, 0.166239001]]
      
      static = UnitConversions.convert(0.5,"inH2O","Pa") # Pascal

      # Cooling Coil
      rated_airflow_rate = 355.2 # cfm
      cfms_ton_rated = calc_cfms_ton_rated(rated_airflow_rate, fan_speed_ratios, capacity_ratios)
      cooling_eirs = calc_cooling_eirs(num_speeds, eers, fan_power_rated)
      shrs_rated_gross = calc_shrs_rated_gross(num_speeds, shrs, fan_power_rated, cfms_ton_rated)
      cOOL_CLOSS_FPLR_SPEC = [calc_plr_coefficients_cooling(num_speeds, seer)] * num_speeds

      obj_name = Constants.ObjectNameCentralAirConditioner(unit.name.to_s)
      
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
    
        # Remove existing equipment
        htg_coil, _perf = remove_existing_hvac_equipment(model, runner, Constants.ObjectNameCentralAirConditioner, control_zone, false, unit)

        # _processCurvesDXCooling
        
        clg_coil_stage_data = calc_coil_stage_data_cooling(model, capacity, num_speeds, cooling_eirs, shrs_rated_gross, cOOL_CAP_FT_SPEC, cOOL_EIR_FT_SPEC, cOOL_CLOSS_FPLR_SPEC, cOOL_CAP_FFLOW_SPEC, cOOL_EIR_FFLOW_SPEC, dse)

        # _processSystemCoolingCoil
        
        clg_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
        clg_coil.setName(obj_name + " cooling coil")
        clg_coil.setCondenserType("AirCooled")
        clg_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(false)
        clg_coil.setApplyLatentDegradationtoSpeedsGreaterthan1(false)
        clg_coil.setCrankcaseHeaterCapacity(UnitConversions.convert(crankcase_capacity,"kW","W"))
        clg_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(UnitConversions.convert(crankcase_temp,"F","C"))
        
        clg_coil.setFuelType("Electricity")
             
        clg_coil_stage_data.each do |stage|
            clg_coil.addStage(stage)
        end
          
        # _processSystemFan     
        if not htg_coil.nil?
          begin
            fuel_type = HelperMethods.reverse_eplus_fuel_map(htg_coil.fuelType)
          rescue
            fuel_type = Constants.FuelTypeElectric
          end
          obj_name = Constants.ObjectNameFurnaceAndCentralAirConditioner(fuel_type, unit.name.to_s)
        end
        
        fan_power_curve = create_curve_exponent(model, [0, 1, 3], obj_name + " fan power curve", -100, 100)        
        fan_eff_curve = create_curve_cubic(model, [0, 1, 0, 0], obj_name + " fan eff curve", 0, 1, 0.01, 1)
        
        fan = OpenStudio::Model::FanOnOff.new(model, model.alwaysOnDiscreteSchedule, fan_power_curve, fan_eff_curve)
        fan.setName(obj_name + " supply fan")
        fan.setEndUseSubcategory(Constants.EndUseHVACFan)
        fan.setFanEfficiency(dse * calculate_fan_efficiency(static, fan_power_installed))
        fan.setPressureRise(static)
        fan.setMotorEfficiency(dse * 1.0)
        fan.setMotorInAirstreamFraction(1.0)
      
        # _processSystemAir
              
        air_loop_unitary = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
        air_loop_unitary.setName(obj_name + " unitary system")
        air_loop_unitary.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
        air_loop_unitary.setCoolingCoil(clg_coil)      
        if not htg_coil.nil?
          # Add the existing furnace back in
          air_loop_unitary.setHeatingCoil(htg_coil)
        else
          air_loop_unitary.setSupplyAirFlowRateDuringHeatingOperation(0.0000001) # this is when there is no heating present
        end
        air_loop_unitary.setSupplyFan(fan)
        air_loop_unitary.setFanPlacement("BlowThrough")
        air_loop_unitary.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule)
        air_loop_unitary.setMaximumSupplyAirTemperature(UnitConversions.convert(120.0,"F","C"))
        air_loop_unitary.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(0)    
        
        perf = OpenStudio::Model::UnitarySystemPerformanceMultispeed.new(model)
        air_loop_unitary.setDesignSpecificationMultispeedObject(perf)
        perf.setSingleModeOperation(false)
        for speed in 1..num_speeds
          f = OpenStudio::Model::SupplyAirflowRatioField.fromCoolingRatio(fan_speed_ratios[speed-1])
          perf.addSupplyAirflowRatioField(f)
        end
        
        air_loop = OpenStudio::Model::AirLoopHVAC.new(model)
        air_loop.setName(obj_name + " central air system")
        air_supply_inlet_node = air_loop.supplyInletNode
        air_supply_outlet_node = air_loop.supplyOutletNode
        air_demand_inlet_node = air_loop.demandInletNode
        air_demand_outlet_node = air_loop.demandOutletNode    
        
        air_loop_unitary.addToNode(air_supply_inlet_node)
        
        runner.registerInfo("Added '#{fan.name}' to #{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{clg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        unless htg_coil.nil?
          runner.registerInfo("Added '#{htg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        end
        
        air_loop_unitary.setControllingZoneorThermostatLocation(control_zone)
        
        # _processSystemDemandSideAir
        # Demand Side

        # Supply Air
        zone_splitter = air_loop.zoneSplitter
        zone_splitter.setName(obj_name + " zone splitter")
        
        zone_mixer = air_loop.zoneMixer
        zone_mixer.setName(obj_name + " zone mixer")

        diffuser_living = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
        diffuser_living.setName(obj_name + " #{control_zone.name} direct air")
        air_loop.addBranchForZone(control_zone, diffuser_living.to_StraightComponent)

        air_loop.addBranchForZone(control_zone)
        runner.registerInfo("Added '#{air_loop.name}' to '#{control_zone.name}' of #{unit.name}")

        prioritize_zone_hvac(model, runner, control_zone)
        
        slave_zones.each do |slave_zone|

          # Remove existing equipment
          remove_existing_hvac_equipment(model, runner, Constants.ObjectNameCentralAirConditioner, slave_zone, false, unit)
      
          diffuser_fbsmt = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
          diffuser_fbsmt.setName(obj_name + " #{slave_zone.name} direct air")
          air_loop.addBranchForZone(slave_zone, diffuser_fbsmt.to_StraightComponent)

          air_loop.addBranchForZone(slave_zone)
          runner.registerInfo("Added '#{air_loop.name}' to '#{slave_zone.name}' of #{unit.name}")

          prioritize_zone_hvac(model, runner, slave_zone)
          
        end # slave_zone
      
      end # control_zone
      
      # Store info for HVAC Sizing measure
      unit.setFeature(Constants.SizingInfoHVACCapacityRatioCooling, capacity_ratios.join(","))
      unit.setFeature(Constants.SizingInfoHVACCapacityDerateFactorEER, eer_capacity_derates.join(","))
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonCooling, cfms_ton_rated.join(","))
      
      return true
      
    end
    
    def self.apply_central_ac_4speed(model, unit, runner, seer, eers, shrs,
                                     capacity_ratios, fan_speed_ratios,
                                     fan_power_rated, fan_power_installed,
                                     crankcase_capacity, crankcase_temp,
                                     eer_capacity_derates, capacity, dse)
       
      num_speeds = 4
      
      # Performance curves
      # NOTE: These coefficients are in IP UNITS
      cOOL_CAP_FT_SPEC = [[3.845135427537, -0.095933272242, 0.000924533273, 0.008939030321, -0.000021025870, -0.000191684744], 
                          [1.902445285801, -0.042809294549, 0.000555959865, 0.009928999493, -0.000013373437, -0.000211453245], 
                          [-3.176259152730, 0.107498394091, -0.000574951600, 0.005484032413, -0.000011584801, -0.000135528854],
                          [1.216308942608, -0.021962441981, 0.000410292252, 0.007362335339, -0.000000025748, -0.000202117724]]
      cOOL_EIR_FT_SPEC = [[-1.400822352, 0.075567798, -0.000589362, -0.024655521, 0.00032690848, -0.00010222178], 
                          [3.278112067, -0.07106453, 0.000468081, -0.014070845, 0.00022267912, -0.00004950051], 
                          [1.183747649, -0.041423179, 0.000390378, 0.021207528, 0.00011181091, -0.00034107189], 
                          [-3.97662986, 0.115338094, -0.000841943, 0.015962287, 0.00007757092, -0.00018579409]]
      cOOL_CAP_FFLOW_SPEC = [[1, 0, 0]] * num_speeds
      cOOL_EIR_FFLOW_SPEC = [[1, 0, 0]] * num_speeds
      
      static = UnitConversions.convert(0.5,"inH2O","Pa") # Pascal

      # Cooling Coil
      rated_airflow_rate = 315.8 # cfm
      cfms_ton_rated = calc_cfms_ton_rated(rated_airflow_rate, fan_speed_ratios, capacity_ratios)
      cooling_eirs = calc_cooling_eirs(num_speeds, eers, fan_power_rated)
      shrs_rated_gross = calc_shrs_rated_gross(num_speeds, shrs, fan_power_rated, cfms_ton_rated)
      cOOL_CLOSS_FPLR_SPEC = [calc_plr_coefficients_cooling(num_speeds, seer)] * num_speeds

      obj_name = Constants.ObjectNameCentralAirConditioner(unit.name.to_s)
      
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
    
        # Remove existing equipment
        htg_coil, _perf = remove_existing_hvac_equipment(model, runner, Constants.ObjectNameCentralAirConditioner, control_zone, false, unit)

        # _processCurvesDXCooling
        
        clg_coil_stage_data = calc_coil_stage_data_cooling(model, capacity, num_speeds, cooling_eirs, shrs_rated_gross, cOOL_CAP_FT_SPEC, cOOL_EIR_FT_SPEC, cOOL_CLOSS_FPLR_SPEC, cOOL_CAP_FFLOW_SPEC, cOOL_EIR_FFLOW_SPEC, dse)

        # _processSystemCoolingCoil
        
        clg_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
        clg_coil.setName(obj_name + " cooling coil")
        clg_coil.setCondenserType("AirCooled")
        clg_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(false)
        clg_coil.setApplyLatentDegradationtoSpeedsGreaterthan1(false)
        clg_coil.setCrankcaseHeaterCapacity(UnitConversions.convert(crankcase_capacity,"kW","W"))
        clg_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(UnitConversions.convert(crankcase_temp,"F","C"))
        
        clg_coil.setFuelType("Electricity")
             
        clg_coil_stage_data.each do |stage|
            clg_coil.addStage(stage)
        end
          
        # _processSystemFan
        if not htg_coil.nil?
          begin
            fuel_type = HelperMethods.reverse_eplus_fuel_map(htg_coil.fuelType)
          rescue
            fuel_type = Constants.FuelTypeElectric
          end
          obj_name = Constants.ObjectNameFurnaceAndCentralAirConditioner(fuel_type, unit.name.to_s)
        end
        
        fan_power_curve = create_curve_exponent(model, [0, 1, 3], obj_name + " fan power curve", -100, 100)        
        fan_eff_curve = create_curve_cubic(model, [0, 1, 0, 0], obj_name + " fan eff curve", 0, 1, 0.01, 1)
        
        fan = OpenStudio::Model::FanOnOff.new(model, model.alwaysOnDiscreteSchedule, fan_power_curve, fan_eff_curve)
        fan.setName(obj_name + " supply fan")
        fan.setEndUseSubcategory(Constants.EndUseHVACFan)
        fan.setFanEfficiency(dse * calculate_fan_efficiency(static, fan_power_installed))
        fan.setPressureRise(static)
        fan.setMotorEfficiency(dse * 1.0)
        fan.setMotorInAirstreamFraction(1.0)
      
        # _processSystemAir
              
        air_loop_unitary = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
        air_loop_unitary.setName(obj_name + " unitary system")
        air_loop_unitary.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
        air_loop_unitary.setCoolingCoil(clg_coil)      
        if not htg_coil.nil?
          # Add the existing furnace back in
          air_loop_unitary.setHeatingCoil(htg_coil)
        else
          air_loop_unitary.setSupplyAirFlowRateDuringHeatingOperation(0.0000001) # this is when there is no heating present
        end
        air_loop_unitary.setSupplyFan(fan)
        air_loop_unitary.setFanPlacement("BlowThrough")
        air_loop_unitary.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule)
        air_loop_unitary.setMaximumSupplyAirTemperature(UnitConversions.convert(120.0,"F","C"))
        air_loop_unitary.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(0)    
        
        perf = OpenStudio::Model::UnitarySystemPerformanceMultispeed.new(model)
        air_loop_unitary.setDesignSpecificationMultispeedObject(perf)
        perf.setSingleModeOperation(false)
        for speed in 1..num_speeds
          f = OpenStudio::Model::SupplyAirflowRatioField.fromCoolingRatio(fan_speed_ratios[speed-1])
          perf.addSupplyAirflowRatioField(f)
        end
        
        air_loop = OpenStudio::Model::AirLoopHVAC.new(model)
        air_loop.setName(obj_name + " central air system")
        air_supply_inlet_node = air_loop.supplyInletNode
        air_supply_outlet_node = air_loop.supplyOutletNode
        air_demand_inlet_node = air_loop.demandInletNode
        air_demand_outlet_node = air_loop.demandOutletNode    
        
        air_loop_unitary.addToNode(air_supply_inlet_node)
        
        runner.registerInfo("Added '#{fan.name}' to #{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{clg_coil.name}' to #{air_loop_unitary.name}' of '#{air_loop.name}'")
        unless htg_coil.nil?
          runner.registerInfo("Added '#{htg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        end
        
        air_loop_unitary.setControllingZoneorThermostatLocation(control_zone)
        
        # _processSystemDemandSideAir
        # Demand Side

        # Supply Air
        zone_splitter = air_loop.zoneSplitter
        zone_splitter.setName(obj_name + " zone splitter")
        
        zone_mixer = air_loop.zoneMixer
        zone_mixer.setName(obj_name + " zone mixer")

        diffuser_living = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
        diffuser_living.setName(obj_name + " #{control_zone.name} direct air")
        air_loop.addBranchForZone(control_zone, diffuser_living.to_StraightComponent)

        air_loop.addBranchForZone(control_zone)
        runner.registerInfo("Added '#{air_loop.name}' to '#{control_zone.name}' of #{unit.name}")

        prioritize_zone_hvac(model, runner, control_zone)
        
        slave_zones.each do |slave_zone|

          # Remove existing equipment
          remove_existing_hvac_equipment(model, runner, Constants.ObjectNameCentralAirConditioner, slave_zone, false, unit)
      
          diffuser_fbsmt = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
          diffuser_fbsmt.setName(obj_name + " #{slave_zone.name} direct air")
          air_loop.addBranchForZone(slave_zone, diffuser_fbsmt.to_StraightComponent)

          air_loop.addBranchForZone(slave_zone)
          runner.registerInfo("Added '#{air_loop.name}' to '#{slave_zone.name}' of #{unit.name}")

          prioritize_zone_hvac(model, runner, slave_zone)
          
        end # slave_zone
      
      end # control_zone
      
      # Store info for HVAC Sizing measure
      unit.setFeature(Constants.SizingInfoHVACCapacityRatioCooling, capacity_ratios.join(","))
      unit.setFeature(Constants.SizingInfoHVACCapacityDerateFactorEER, eer_capacity_derates.join(","))
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonCooling, cfms_ton_rated.join(","))
      
      return true
    end
    
    def self.apply_central_ashp_1speed(model, unit, runner, seer, hspf, eers, cops, shrs,
                                       fan_power_rated, fan_power_installed, min_temp,
                                       crankcase_capacity, crankcase_temp,
                                       eer_capacity_derates, cop_capacity_derates,
                                       heat_pump_capacity, supplemental_efficiency,
                                       supplemental_capacity, dse)
    
      if heat_pump_capacity == Constants.SizingAutoMaxLoad
          runner.registerWarning("Using #{Constants.SizingAutoMaxLoad} is not recommended for single-speed heat pumps. When sized larger than the cooling load, this can lead to humidity concerns due to reduced dehumidification performance by the heat pump.")
      end
      
      num_speeds = 1
      
      # Performance curves
      # NOTE: These coefficients are in IP UNITS
      cOOL_CAP_FT_SPEC = [[3.68637657, -0.098352478, 0.000956357, 0.005838141, -0.0000127, -0.000131702]]
      cOOL_EIR_FT_SPEC = [[-3.437356399, 0.136656369, -0.001049231, -0.0079378, 0.000185435, -0.0001441]]
      cOOL_CAP_FFLOW_SPEC = [[0.718664047, 0.41797409, -0.136638137]]
      cOOL_EIR_FFLOW_SPEC = [[1.143487507, -0.13943972, -0.004047787]]
      hEAT_CAP_FT_SPEC = [[0.566333415, -0.000744164, -0.0000103, 0.009414634, 0.0000506, -0.00000675]]
      hEAT_EIR_FT_SPEC = [[0.718398423, 0.003498178, 0.000142202, -0.005724331, 0.00014085, -0.000215321]]
      hEAT_CAP_FFLOW_SPEC = [[0.694045465, 0.474207981, -0.168253446]]
      hEAT_EIR_FFLOW_SPEC = [[2.185418751, -1.942827919, 0.757409168]]

      static = UnitConversions.convert(0.5,"inH2O","Pa") # Pascal

      capacity_ratios = [1.0]
      fan_speed_ratios_cooling = [1.0]
      fan_speed_ratios_heating = [1.0]
      
      # Cooling Coil
      rated_airflow_rate_cooling = 394.2 # cfm
      cfms_ton_rated_cooling = calc_cfms_ton_rated(rated_airflow_rate_cooling, fan_speed_ratios_cooling, capacity_ratios)
      cooling_eirs = calc_cooling_eirs(num_speeds, eers, fan_power_rated)
      shrs_rated_gross = calc_shrs_rated_gross(num_speeds, shrs, fan_power_rated, cfms_ton_rated_cooling)
      cOOL_CLOSS_FPLR_SPEC = [calc_plr_coefficients_cooling(num_speeds, seer)]

      # Heating Coil
      rated_airflow_rate_heating = 384.1 # cfm
      cfms_ton_rated_heating = calc_cfms_ton_rated(rated_airflow_rate_heating, fan_speed_ratios_heating, capacity_ratios)
      heating_eirs = calc_heating_eirs(num_speeds, cops, fan_power_rated)
      hEAT_CLOSS_FPLR_SPEC = [calc_plr_coefficients_heating(num_speeds, hspf)]
      
      # Heating defrost curve for reverse cycle
      defrost_eir_curve = create_curve_biquadratic(model, [0.1528, 0, 0, 0, 0, 0], "DefrostEIR", -100, 100, -100, 100)
    
      obj_name = Constants.ObjectNameAirSourceHeatPump(unit.name.to_s)
    
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
    
        # Remove existing equipment
        remove_existing_hvac_equipment(model, runner, Constants.ObjectNameAirSourceHeatPump, control_zone, false, unit)
      
        # _processCurvesDXHeating
        htg_coil_stage_data = calc_coil_stage_data_heating(model, heat_pump_capacity, num_speeds, heating_eirs, hEAT_CAP_FT_SPEC, hEAT_EIR_FT_SPEC, hEAT_CLOSS_FPLR_SPEC, hEAT_CAP_FFLOW_SPEC, hEAT_EIR_FFLOW_SPEC, dse)
      
        # _processSystemHeatingCoil
        
        htg_coil = OpenStudio::Model::CoilHeatingDXSingleSpeed.new(model, model.alwaysOnDiscreteSchedule, htg_coil_stage_data[0].heatingCapacityFunctionofTemperatureCurve, htg_coil_stage_data[0].heatingCapacityFunctionofFlowFractionCurve, htg_coil_stage_data[0].energyInputRatioFunctionofTemperatureCurve, htg_coil_stage_data[0].energyInputRatioFunctionofFlowFractionCurve, htg_coil_stage_data[0].partLoadFractionCorrelationCurve)
        htg_coil_stage_data[0].remove
        htg_coil.setName(obj_name + " heating coil")
        if heat_pump_capacity != Constants.SizingAuto and heat_pump_capacity != Constants.SizingAutoMaxLoad
          htg_coil.setRatedTotalHeatingCapacity(UnitConversions.convert(heat_pump_capacity,"Btu/hr","W")) # Used by HVACSizing measure
        end
        htg_coil.setRatedCOP(dse / heating_eirs[0])
        htg_coil.setRatedSupplyFanPowerPerVolumeFlowRate(fan_power_rated / UnitConversions.convert(1.0,"cfm","m^3/s"))
        htg_coil.setDefrostEnergyInputRatioFunctionofTemperatureCurve(defrost_eir_curve)
        htg_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(UnitConversions.convert(min_temp,"F","C"))
        htg_coil.setMaximumOutdoorDryBulbTemperatureforDefrostOperation(UnitConversions.convert(40.0,"F","C"))
        htg_coil.setCrankcaseHeaterCapacity(UnitConversions.convert(crankcase_capacity,"kW","W"))
        htg_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(UnitConversions.convert(crankcase_temp,"F","C"))
        htg_coil.setDefrostStrategy("ReverseCycle")
        htg_coil.setDefrostControl("OnDemand")
        
        supp_htg_coil = OpenStudio::Model::CoilHeatingElectric.new(model, model.alwaysOnDiscreteSchedule)
        supp_htg_coil.setName(obj_name + " supp heater")
        supp_htg_coil.setEfficiency(dse * supplemental_efficiency)
        if supplemental_capacity != Constants.SizingAuto
          supp_htg_coil.setNominalCapacity(UnitConversions.convert(supplemental_capacity,"Btu/hr","W")) # Used by HVACSizing measure
        end
        
        # _processCurvesDXCooling

        clg_coil_stage_data = calc_coil_stage_data_cooling(model, heat_pump_capacity, num_speeds, cooling_eirs, shrs_rated_gross, cOOL_CAP_FT_SPEC, cOOL_EIR_FT_SPEC, cOOL_CLOSS_FPLR_SPEC, cOOL_CAP_FFLOW_SPEC, cOOL_EIR_FFLOW_SPEC, dse)
        
        # _processSystemCoolingCoil
        
        clg_coil = OpenStudio::Model::CoilCoolingDXSingleSpeed.new(model, model.alwaysOnDiscreteSchedule, clg_coil_stage_data[0].totalCoolingCapacityFunctionofTemperatureCurve, clg_coil_stage_data[0].totalCoolingCapacityFunctionofFlowFractionCurve, clg_coil_stage_data[0].energyInputRatioFunctionofTemperatureCurve, clg_coil_stage_data[0].energyInputRatioFunctionofFlowFractionCurve, clg_coil_stage_data[0].partLoadFractionCorrelationCurve)
        clg_coil_stage_data[0].remove
        clg_coil.setName(obj_name + " cooling coil")
        if heat_pump_capacity != Constants.SizingAuto and heat_pump_capacity != Constants.SizingAutoMaxLoad
          clg_coil.setRatedTotalCoolingCapacity(UnitConversions.convert(heat_pump_capacity,"Btu/hr","W")) # Used by HVACSizing measure
        end
        clg_coil.setRatedSensibleHeatRatio(shrs_rated_gross[0])
        clg_coil.setRatedCOP(OpenStudio::OptionalDouble.new(dse / cooling_eirs[0]))
        clg_coil.setRatedEvaporatorFanPowerPerVolumeFlowRate(OpenStudio::OptionalDouble.new(fan_power_rated / UnitConversions.convert(1.0,"cfm","m^3/s")))
        clg_coil.setNominalTimeForCondensateRemovalToBegin(OpenStudio::OptionalDouble.new(1000.0))
        clg_coil.setRatioOfInitialMoistureEvaporationRateAndSteadyStateLatentCapacity(OpenStudio::OptionalDouble.new(1.5))
        clg_coil.setMaximumCyclingRate(OpenStudio::OptionalDouble.new(3.0))
        clg_coil.setLatentCapacityTimeConstant(OpenStudio::OptionalDouble.new(45.0))
        clg_coil.setCondenserType("AirCooled")   
        
        # _processSystemFan

        fan = OpenStudio::Model::FanOnOff.new(model, model.alwaysOnDiscreteSchedule)
        fan.setName(obj_name + " supply fan")
        fan.setEndUseSubcategory(Constants.EndUseHVACFan)
        fan.setFanEfficiency(dse * calculate_fan_efficiency(static, fan_power_installed))
        fan.setPressureRise(static)
        fan.setMotorEfficiency(dse * 1.0)
        fan.setMotorInAirstreamFraction(1.0)
        
        # _processSystemAir
                 
        air_loop_unitary = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
        air_loop_unitary.setName(obj_name + " unitary system")
        air_loop_unitary.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
        air_loop_unitary.setSupplyFan(fan)
        air_loop_unitary.setHeatingCoil(htg_coil)
        air_loop_unitary.setCoolingCoil(clg_coil)
        air_loop_unitary.setSupplementalHeatingCoil(supp_htg_coil)
        air_loop_unitary.setFanPlacement("BlowThrough")
        air_loop_unitary.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule)
        air_loop_unitary.setMaximumSupplyAirTemperature(UnitConversions.convert(170.0,"F","C")) # higher temp for supplemental heat as to not severely limit its use, resulting in unmet hours.
        air_loop_unitary.setMaximumOutdoorDryBulbTemperatureforSupplementalHeaterOperation(UnitConversions.convert(40.0,"F","C"))
        air_loop_unitary.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(0)
          
        air_loop = OpenStudio::Model::AirLoopHVAC.new(model)
        air_loop.setName(obj_name + " central air system")
        air_supply_inlet_node = air_loop.supplyInletNode
        air_supply_outlet_node = air_loop.supplyOutletNode
        air_demand_inlet_node = air_loop.demandInletNode
        air_demand_outlet_node = air_loop.demandOutletNode    
        
        air_loop_unitary.addToNode(air_supply_inlet_node)
        
        runner.registerInfo("Added '#{fan.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{clg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{htg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{supp_htg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")    
        
        air_loop_unitary.setControllingZoneorThermostatLocation(control_zone)
          
        # _processSystemDemandSideAir
        # Demand Side

        # Supply Air
        zone_splitter = air_loop.zoneSplitter
        zone_splitter.setName(obj_name + " zone splitter")
        
        zone_mixer = air_loop.zoneMixer
        zone_mixer.setName(obj_name + " zone mixer")

        diffuser_living = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
        diffuser_living.setName(obj_name + " #{control_zone.name} direct air")
        air_loop.addBranchForZone(control_zone, diffuser_living.to_StraightComponent)

        air_loop.addBranchForZone(control_zone)
        runner.registerInfo("Added '#{air_loop.name}' to '#{control_zone.name}' of #{unit.name}")

        prioritize_zone_hvac(model, runner, control_zone)
        
        slave_zones.each do |slave_zone|

          # Remove existing equipment
          remove_existing_hvac_equipment(model, runner, Constants.ObjectNameAirSourceHeatPump, slave_zone, false, unit)
      
          diffuser_fbsmt = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
          diffuser_fbsmt.setName(obj_name + " #{slave_zone.name} direct air")
          air_loop.addBranchForZone(slave_zone, diffuser_fbsmt.to_StraightComponent)

          air_loop.addBranchForZone(slave_zone)
          runner.registerInfo("Added '#{air_loop.name}' to '#{slave_zone.name}' of #{unit.name}")

          prioritize_zone_hvac(model, runner, slave_zone)
          
        end # slave_zone
      
      end # control_zone
      
      # Store info for HVAC Sizing measure
      unit.setFeature(Constants.SizingInfoHVACCapacityDerateFactorEER, eer_capacity_derates.join(","))
      unit.setFeature(Constants.SizingInfoHVACCapacityDerateFactorCOP, cop_capacity_derates.join(","))
      unit.setFeature(Constants.SizingInfoHPSizedForMaxLoad, (heat_pump_capacity == Constants.SizingAutoMaxLoad))
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonHeating, cfms_ton_rated_heating.join(","))
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonCooling, cfms_ton_rated_cooling.join(","))
    
      return true
    end
    
    def self.apply_central_ashp_2speed(model, unit, runner, seer, hspf, eers, cops, shrs,
                                       capacity_ratios, fan_speed_ratios_cooling,
                                       fan_speed_ratios_heating,
                                       fan_power_rated, fan_power_installed, min_temp,
                                       crankcase_capacity, crankcase_temp,
                                       eer_capacity_derates, cop_capacity_derates,
                                       heat_pump_capacity, supplemental_efficiency,
                                       supplemental_capacity, dse)
                                       
      num_speeds = 2
      
      # Performance curves
      # NOTE: These coefficients are in IP UNITS
      cOOL_CAP_FT_SPEC = [[3.998418659, -0.108728222, 0.001056818, 0.007512314, -0.0000139, -0.000164716], 
                          [3.466810106, -0.091476056, 0.000901205, 0.004163355, -0.00000919, -0.000110829]]
      cOOL_EIR_FT_SPEC = [[-4.282911381, 0.181023691, -0.001357391, -0.026310378, 0.000333282, -0.000197405], 
                          [-3.557757517, 0.112737397, -0.000731381, 0.013184877, 0.000132645, -0.000338716]]
      cOOL_CAP_FFLOW_SPEC = [[0.655239515, 0.511655216, -0.166894731], 
                             [0.618281092, 0.569060264, -0.187341356]]
      cOOL_EIR_FFLOW_SPEC = [[1.639108268, -0.998953996, 0.359845728], 
                             [1.570774717, -0.914152018, 0.343377302]]
      hEAT_CAP_FT_SPEC = [[0.335690634, 0.002405123, -0.0000464, 0.013498735, 0.0000499, -0.00000725], 
                          [0.306358843, 0.005376987, -0.0000579, 0.011645092, 0.0000591, -0.0000203]]
      hEAT_EIR_FT_SPEC = [[0.36338171, 0.013523725, 0.000258872, -0.009450269, 0.000439519, -0.000653723], 
                          [0.981100941, -0.005158493, 0.000243416, -0.005274352, 0.000230742, -0.000336954]]
      hEAT_CAP_FFLOW_SPEC = [[0.741466907, 0.378645444, -0.119754733], 
                             [0.76634609, 0.32840943, -0.094701495]]
      hEAT_EIR_FFLOW_SPEC = [[2.153618211, -1.737190609, 0.584269478], 
                             [2.001041353, -1.58869128, 0.587593517]]

      static = UnitConversions.convert(0.5,"inH2O","Pa") # Pascal

      # Cooling Coil
      rated_airflow_rate_cooling = 344.1 # cfm
      cfms_ton_rated_cooling = calc_cfms_ton_rated(rated_airflow_rate_cooling, fan_speed_ratios_cooling, capacity_ratios)
      cooling_eirs = calc_cooling_eirs(num_speeds, eers, fan_power_rated)
      shrs_rated_gross = calc_shrs_rated_gross(num_speeds, shrs, fan_power_rated, cfms_ton_rated_cooling)
      cOOL_CLOSS_FPLR_SPEC = [calc_plr_coefficients_cooling(num_speeds, seer)] * num_speeds

      # Heating Coil
      rated_airflow_rate_heating = 352.2 # cfm
      cfms_ton_rated_heating = calc_cfms_ton_rated(rated_airflow_rate_heating, fan_speed_ratios_heating, capacity_ratios)
      heating_eirs = calc_heating_eirs(num_speeds, cops, fan_power_rated)
      hEAT_CLOSS_FPLR_SPEC = [calc_plr_coefficients_heating(num_speeds, hspf)] * num_speeds
      
      # Heating defrost curve for reverse cycle
      defrost_eir_curve = create_curve_biquadratic(model, [0.1528, 0, 0, 0, 0, 0], "DefrostEIR", -100, 100, -100, 100)
    
      obj_name = Constants.ObjectNameAirSourceHeatPump(unit.name.to_s)
      
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
    
        # Remove existing equipment
        remove_existing_hvac_equipment(model, runner, Constants.ObjectNameAirSourceHeatPump, control_zone, false, unit)
      
        # _processCurvesDXHeating
        htg_coil_stage_data = calc_coil_stage_data_heating(model, heat_pump_capacity, num_speeds, heating_eirs, hEAT_CAP_FT_SPEC, hEAT_EIR_FT_SPEC, hEAT_CLOSS_FPLR_SPEC, hEAT_CAP_FFLOW_SPEC, hEAT_EIR_FFLOW_SPEC, dse)
      
        # _processSystemHeatingCoil        

        htg_coil = OpenStudio::Model::CoilHeatingDXMultiSpeed.new(model)
        htg_coil.setName(obj_name + " heating coil")
        htg_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(UnitConversions.convert(min_temp,"F","C"))
        htg_coil.setCrankcaseHeaterCapacity(UnitConversions.convert(crankcase_capacity,"kW","W"))
        htg_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(UnitConversions.convert(crankcase_temp,"F","C"))
        htg_coil.setDefrostEnergyInputRatioFunctionofTemperatureCurve(defrost_eir_curve)
        htg_coil.setMaximumOutdoorDryBulbTemperatureforDefrostOperation(UnitConversions.convert(40.0,"F","C"))
        htg_coil.setDefrostStrategy("ReverseCryle")
        htg_coil.setDefrostControl("OnDemand")
        htg_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(false)
        htg_coil.setFuelType("Electricity")
        
        htg_coil_stage_data.each do |stage|
            htg_coil.addStage(stage)
        end
        
        supp_htg_coil = OpenStudio::Model::CoilHeatingElectric.new(model, model.alwaysOnDiscreteSchedule)
        supp_htg_coil.setName(obj_name + " supp heater")
        supp_htg_coil.setEfficiency(dse * supplemental_efficiency)
        if supplemental_capacity != Constants.SizingAuto
          supp_htg_coil.setNominalCapacity(UnitConversions.convert(supplemental_capacity,"Btu/hr","W")) # Used by HVACSizing measure
        end
        
        # _processCurvesDXCooling

        clg_coil_stage_data = calc_coil_stage_data_cooling(model, heat_pump_capacity, num_speeds, cooling_eirs, shrs_rated_gross, cOOL_CAP_FT_SPEC, cOOL_EIR_FT_SPEC, cOOL_CLOSS_FPLR_SPEC, cOOL_CAP_FFLOW_SPEC, cOOL_EIR_FFLOW_SPEC, dse)
        
        # _processSystemCoolingCoil
        
        clg_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
        clg_coil.setName(obj_name + " cooling coil")
        clg_coil.setCondenserType("AirCooled")
        clg_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(false)
        clg_coil.setApplyLatentDegradationtoSpeedsGreaterthan1(false)        
        clg_coil.setFuelType("Electricity")
             
        clg_coil_stage_data.each do |stage|
            clg_coil.addStage(stage)
        end   
        
        # _processSystemFan

        fan_power_curve = create_curve_exponent(model, [0, 1, 3], obj_name + " fan power curve", -100, 100)        
        fan_eff_curve = create_curve_cubic(model, [0, 1, 0, 0], obj_name + " fan eff curve", 0, 1, 0.01, 1)
        
        fan = OpenStudio::Model::FanOnOff.new(model, model.alwaysOnDiscreteSchedule, fan_power_curve, fan_eff_curve)
        fan.setName(obj_name + " supply fan")
        fan.setEndUseSubcategory(Constants.EndUseHVACFan)
        fan.setFanEfficiency(dse * calculate_fan_efficiency(static, fan_power_installed))
        fan.setPressureRise(static)
        fan.setMotorEfficiency(dse * 1.0)
        fan.setMotorInAirstreamFraction(1.0)
        
        # _processSystemAir
                 
        air_loop_unitary = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
        air_loop_unitary.setName(obj_name + " unitary system")
        air_loop_unitary.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
        air_loop_unitary.setSupplyFan(fan)
        air_loop_unitary.setHeatingCoil(htg_coil)
        air_loop_unitary.setCoolingCoil(clg_coil)
        air_loop_unitary.setSupplementalHeatingCoil(supp_htg_coil)
        air_loop_unitary.setFanPlacement("BlowThrough")
        air_loop_unitary.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule)
        air_loop_unitary.setMaximumSupplyAirTemperature(UnitConversions.convert(170.0,"F","C")) # higher temp for supplemental heat as to not severely limit its use, resulting in unmet hours.
        air_loop_unitary.setMaximumOutdoorDryBulbTemperatureforSupplementalHeaterOperation(UnitConversions.convert(40.0,"F","C"))
        air_loop_unitary.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(0)
          
        perf = OpenStudio::Model::UnitarySystemPerformanceMultispeed.new(model)
        air_loop_unitary.setDesignSpecificationMultispeedObject(perf)
        perf.setSingleModeOperation(false)
        for speed in 1..num_speeds
          f = OpenStudio::Model::SupplyAirflowRatioField.new(fan_speed_ratios_heating[speed-1], fan_speed_ratios_cooling[speed-1])
          perf.addSupplyAirflowRatioField(f)
        end
        
        air_loop = OpenStudio::Model::AirLoopHVAC.new(model)
        air_loop.setName(obj_name + " central air system")
        air_supply_inlet_node = air_loop.supplyInletNode
        air_supply_outlet_node = air_loop.supplyOutletNode
        air_demand_inlet_node = air_loop.demandInletNode
        air_demand_outlet_node = air_loop.demandOutletNode    
        
        air_loop_unitary.addToNode(air_supply_inlet_node)
        
        runner.registerInfo("Added '#{fan.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{clg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{htg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{supp_htg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")    
        
        air_loop_unitary.setControllingZoneorThermostatLocation(control_zone)
          
        # _processSystemDemandSideAir
        # Demand Side

        # Supply Air
        zone_splitter = air_loop.zoneSplitter
        zone_splitter.setName(obj_name + " zone splitter")
        
        zone_mixer = air_loop.zoneMixer
        zone_mixer.setName(obj_name + " zone mixer")

        diffuser_living = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
        diffuser_living.setName(obj_name + " #{control_zone.name} direct air")
        air_loop.addBranchForZone(control_zone, diffuser_living.to_StraightComponent)

        air_loop.addBranchForZone(control_zone)
        runner.registerInfo("Added '#{air_loop.name}' to '#{control_zone.name}' of #{unit.name}")

        prioritize_zone_hvac(model, runner, control_zone)
        
        slave_zones.each do |slave_zone|

          # Remove existing equipment
          remove_existing_hvac_equipment(model, runner, Constants.ObjectNameAirSourceHeatPump, slave_zone, false, unit)
      
          diffuser_fbsmt = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
          diffuser_fbsmt.setName(obj_name + " #{slave_zone.name} direct air")
          air_loop.addBranchForZone(slave_zone, diffuser_fbsmt.to_StraightComponent)

          air_loop.addBranchForZone(slave_zone)
          runner.registerInfo("Added '#{air_loop.name}' to '#{slave_zone.name}' of #{unit.name}")

          prioritize_zone_hvac(model, runner, slave_zone)
          
        end # slave_zone
      
      end # control_zone
      
      # Store info for HVAC Sizing measure
      unit.setFeature(Constants.SizingInfoHVACCapacityRatioCooling, capacity_ratios.join(","))
      unit.setFeature(Constants.SizingInfoHVACCapacityDerateFactorEER, eer_capacity_derates.join(","))
      unit.setFeature(Constants.SizingInfoHVACCapacityDerateFactorCOP, cop_capacity_derates.join(","))
      unit.setFeature(Constants.SizingInfoHPSizedForMaxLoad, (heat_pump_capacity == Constants.SizingAutoMaxLoad))
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonHeating, cfms_ton_rated_heating.join(","))
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonCooling, cfms_ton_rated_cooling.join(","))
    
      return true
    end

    def self.apply_central_ashp_4speed(model, unit, runner, seer, hspf, eers, cops, shrs,
                                       capacity_ratios, fan_speed_ratios_cooling,
                                       fan_speed_ratios_heating,
                                       fan_power_rated, fan_power_installed, min_temp,
                                       crankcase_capacity, crankcase_temp,
                                       eer_capacity_derates, cop_capacity_derates,
                                       heat_pump_capacity, supplemental_efficiency,
                                       supplemental_capacity, dse)
                                  
      num_speeds = 4
      
      # Performance curves
      # NOTE: These coefficients are in IP UNITS
      cOOL_CAP_FT_SPEC = [[3.63396857, -0.093606786, 0.000918114, 0.011852512, -0.0000318307, -0.000206446],
                          [1.808745668, -0.041963484, 0.000545263, 0.011346539, -0.000023838, -0.000205162],
                          [0.112814745, 0.005638646, 0.000203427, 0.011981545, -0.0000207957, -0.000212379],
                          [1.141506147, -0.023973142, 0.000420763, 0.01038334, -0.0000174633, -0.000197092]]
      cOOL_EIR_FT_SPEC = [[-1.380674217, 0.083176919, -0.000676029, -0.028120348, 0.000320593, -0.0000616147],
                          [4.817787321, -0.100122768, 0.000673499, -0.026889359, 0.00029445, -0.0000390331],
                          [-1.502227232, 0.05896401, -0.000439349, 0.002198465, 0.000148486, -0.000159553],
                          [-3.443078025, 0.115186164, -0.000852001, 0.004678056, 0.000134319, -0.000171976]]
      cOOL_CAP_FFLOW_SPEC = [[1, 0, 0]] * num_speeds
      cOOL_EIR_FFLOW_SPEC = [[1, 0, 0]] * num_speeds
      hEAT_CAP_FT_SPEC = [[0.304192655, -0.003972566, 0.0000196432, 0.024471251, -0.000000774126, -0.0000841323],
                          [0.496381324, -0.00144792, 0.0, 0.016020855, 0.0000203447, -0.0000584118],
                          [0.697171186, -0.006189599, 0.0000337077, 0.014291981, 0.0000105633, -0.0000387956],
                          [0.555513805, -0.001337363, -0.00000265117, 0.014328826, 0.0000163849, -0.0000480711]]
      hEAT_EIR_FT_SPEC = [[0.708311527, 0.020732093, 0.000391479, -0.037640031, 0.000979937, -0.001079042],
                          [0.025480155, 0.020169585, 0.000121341, -0.004429789, 0.000166472, -0.00036447],
                          [0.379003189, 0.014195012, 0.0000821046, -0.008894061, 0.000151519, -0.000210299],
                          [0.690404655, 0.00616619, 0.000137643, -0.009350199, 0.000153427, -0.000213258]]
      hEAT_CAP_FFLOW_SPEC = [[1, 0, 0]] * num_speeds
      hEAT_EIR_FFLOW_SPEC = [[1, 0, 0]] * num_speeds

      static = UnitConversions.convert(0.5,"inH2O","Pa") # Pascal

      # Cooling Coil
      rated_airflow_rate_cooling = 315.8 # cfm
      cfms_ton_rated_cooling = calc_cfms_ton_rated(rated_airflow_rate_cooling, fan_speed_ratios_cooling, capacity_ratios)
      cooling_eirs = calc_cooling_eirs(num_speeds, eers, fan_power_rated)
      shrs_rated_gross = calc_shrs_rated_gross(num_speeds, shrs, fan_power_rated, cfms_ton_rated_cooling)
      cOOL_CLOSS_FPLR_SPEC = [calc_plr_coefficients_cooling(num_speeds, seer)] * num_speeds

      # Heating Coil
      rated_airflow_rate_heating = 296.9 # cfm
      cfms_ton_rated_heating = calc_cfms_ton_rated(rated_airflow_rate_heating, fan_speed_ratios_heating, capacity_ratios)
      heating_eirs = calc_heating_eirs(num_speeds, cops, fan_power_rated)
      hEAT_CLOSS_FPLR_SPEC = [calc_plr_coefficients_heating(num_speeds, hspf)] * num_speeds
      
      # Heating defrost curve for reverse cycle
      defrost_eir_curve = create_curve_biquadratic(model, [0.1528, 0, 0, 0, 0, 0], "DefrostEIR", -100, 100, -100, 100)

      obj_name = Constants.ObjectNameAirSourceHeatPump(unit.name.to_s)
      
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
    
        # Remove existing equipment
        remove_existing_hvac_equipment(model, runner, Constants.ObjectNameAirSourceHeatPump, control_zone, false, unit)
      
        # _processCurvesDXHeating
        
        htg_coil_stage_data = calc_coil_stage_data_heating(model, heat_pump_capacity, num_speeds, heating_eirs, hEAT_CAP_FT_SPEC, hEAT_EIR_FT_SPEC, hEAT_CLOSS_FPLR_SPEC, hEAT_CAP_FFLOW_SPEC, hEAT_EIR_FFLOW_SPEC, dse)
      
        # _processSystemHeatingCoil        

        htg_coil = OpenStudio::Model::CoilHeatingDXMultiSpeed.new(model)
        htg_coil.setName(obj_name + " heating coil")
        htg_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(UnitConversions.convert(min_temp,"F","C"))
        htg_coil.setCrankcaseHeaterCapacity(UnitConversions.convert(crankcase_capacity,"kW","W"))
        htg_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(UnitConversions.convert(crankcase_temp,"F","C"))
        htg_coil.setDefrostEnergyInputRatioFunctionofTemperatureCurve(defrost_eir_curve)
        htg_coil.setMaximumOutdoorDryBulbTemperatureforDefrostOperation(UnitConversions.convert(40.0,"F","C"))
        htg_coil.setDefrostStrategy("ReverseCryle")
        htg_coil.setDefrostControl("OnDemand")
        htg_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(false)
        htg_coil.setFuelType("Electricity")
        
        htg_coil_stage_data.each do |stage|
            htg_coil.addStage(stage)
        end
        
        supp_htg_coil = OpenStudio::Model::CoilHeatingElectric.new(model, model.alwaysOnDiscreteSchedule)
        supp_htg_coil.setName(obj_name + " supp heater")
        supp_htg_coil.setEfficiency(dse * supplemental_efficiency)
        if supplemental_capacity != Constants.SizingAuto
          supp_htg_coil.setNominalCapacity(UnitConversions.convert(supplemental_capacity,"Btu/hr","W")) # Used by HVACSizing measure
        end
        
        # _processCurvesDXCooling

        clg_coil_stage_data = calc_coil_stage_data_cooling(model, heat_pump_capacity, num_speeds, cooling_eirs, shrs_rated_gross, cOOL_CAP_FT_SPEC, cOOL_EIR_FT_SPEC, cOOL_CLOSS_FPLR_SPEC, cOOL_CAP_FFLOW_SPEC, cOOL_EIR_FFLOW_SPEC, dse)
        
        # _processSystemCoolingCoil
        
        clg_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
        clg_coil.setName(obj_name + " cooling coil")
        clg_coil.setCondenserType("AirCooled")
        clg_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(false)
        clg_coil.setApplyLatentDegradationtoSpeedsGreaterthan1(false)        
        clg_coil.setFuelType("Electricity")
             
        clg_coil_stage_data.each do |stage|
            clg_coil.addStage(stage)
        end   
        
        # _processSystemFan
        
        fan_power_curve = create_curve_exponent(model, [0, 1, 3], obj_name + " fan power curve", -100, 100)        
        fan_eff_curve = create_curve_cubic(model, [0, 1, 0, 0], obj_name + " fan eff curve", 0, 1, 0.01, 1)
        
        fan = OpenStudio::Model::FanOnOff.new(model, model.alwaysOnDiscreteSchedule, fan_power_curve, fan_eff_curve)
        fan.setName(obj_name + " supply fan")
        fan.setEndUseSubcategory(Constants.EndUseHVACFan)
        fan.setFanEfficiency(dse * calculate_fan_efficiency(static, fan_power_installed))
        fan.setPressureRise(static)
        fan.setMotorEfficiency(dse * 1.0)
        fan.setMotorInAirstreamFraction(1.0)    
        
        # _processSystemAir
                 
        air_loop_unitary = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
        air_loop_unitary.setName(obj_name + " unitary system")
        air_loop_unitary.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
        air_loop_unitary.setSupplyFan(fan)
        air_loop_unitary.setHeatingCoil(htg_coil)
        air_loop_unitary.setCoolingCoil(clg_coil)
        air_loop_unitary.setSupplementalHeatingCoil(supp_htg_coil)
        air_loop_unitary.setFanPlacement("BlowThrough")
        air_loop_unitary.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule)
        air_loop_unitary.setMaximumSupplyAirTemperature(UnitConversions.convert(170.0,"F","C")) # higher temp for supplemental heat as to not severely limit its use, resulting in unmet hours.
        air_loop_unitary.setMaximumOutdoorDryBulbTemperatureforSupplementalHeaterOperation(UnitConversions.convert(40.0,"F","C"))
        air_loop_unitary.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(0)
          
        perf = OpenStudio::Model::UnitarySystemPerformanceMultispeed.new(model)
        air_loop_unitary.setDesignSpecificationMultispeedObject(perf)
        perf.setSingleModeOperation(false)
        for speed in 1..num_speeds
          f = OpenStudio::Model::SupplyAirflowRatioField.new(fan_speed_ratios_heating[speed-1], fan_speed_ratios_cooling[speed-1])
          perf.addSupplyAirflowRatioField(f)
        end
        
        air_loop = OpenStudio::Model::AirLoopHVAC.new(model)
        air_loop.setName(obj_name + " central air system")
        air_supply_inlet_node = air_loop.supplyInletNode
        air_supply_outlet_node = air_loop.supplyOutletNode
        air_demand_inlet_node = air_loop.demandInletNode
        air_demand_outlet_node = air_loop.demandOutletNode    
        
        air_loop_unitary.addToNode(air_supply_inlet_node)
        
        runner.registerInfo("Added '#{fan.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{clg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{htg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{supp_htg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")    
        
        air_loop_unitary.setControllingZoneorThermostatLocation(control_zone)
          
        # _processSystemDemandSideAir
        # Demand Side

        # Supply Air
        zone_splitter = air_loop.zoneSplitter
        zone_splitter.setName(obj_name + " zone splitter")
        
        zone_mixer = air_loop.zoneMixer
        zone_mixer.setName(obj_name + " zone mixer")

        diffuser_living = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
        diffuser_living.setName(obj_name + " #{control_zone.name} direct air")
        air_loop.addBranchForZone(control_zone, diffuser_living.to_StraightComponent)

        air_loop.addBranchForZone(control_zone)
        runner.registerInfo("Added '#{air_loop.name}' to '#{control_zone.name}' of #{unit.name}")

        prioritize_zone_hvac(model, runner, control_zone)
        
        slave_zones.each do |slave_zone|

          # Remove existing equipment
          remove_existing_hvac_equipment(model, runner, Constants.ObjectNameAirSourceHeatPump, slave_zone, false, unit)
      
          diffuser_fbsmt = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
          diffuser_fbsmt.setName(obj_name + " #{slave_zone.name} direct air")
          air_loop.addBranchForZone(slave_zone, diffuser_fbsmt.to_StraightComponent)

          air_loop.addBranchForZone(slave_zone)
          runner.registerInfo("Added '#{air_loop.name}' to '#{slave_zone.name}' of #{unit.name}")

          prioritize_zone_hvac(model, runner, slave_zone)
          
        end # slave_zone
      
      end # control_zone
      
      # Store info for HVAC Sizing measure
      unit.setFeature(Constants.SizingInfoHVACCapacityRatioCooling, capacity_ratios.join(","))
      unit.setFeature(Constants.SizingInfoHVACCapacityDerateFactorEER, eer_capacity_derates.join(","))
      unit.setFeature(Constants.SizingInfoHVACCapacityDerateFactorCOP, cop_capacity_derates.join(","))
      unit.setFeature(Constants.SizingInfoHPSizedForMaxLoad, (heat_pump_capacity == Constants.SizingAutoMaxLoad))
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonHeating, cfms_ton_rated_heating.join(","))
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonCooling, cfms_ton_rated_cooling.join(","))
      
      return true
    end
    
    def self.apply_mshp(model, unit, runner, seer, hspf, shr,
                        min_cooling_capacity, max_cooling_capacity,
                        min_cooling_airflow_rate, max_cooling_airflow_rate,
                        min_heating_capacity, max_heating_capacity,
                        min_heating_airflow_rate, max_heating_airflow_rate, 
                        heating_capacity_offset, cap_retention_frac,
                        cap_retention_temp, pan_heater_power, fan_power,
                        is_ducted, heat_pump_capacity,
                        supplemental_efficiency, supplemental_capacity,
                        dse)
    
      num_speeds = 10
      
      max_defrost_temp = 40.0 # F
      min_hp_temp = -30.0 # F; Minimum temperature for Heat Pump operation
      static = UnitConversions.convert(0.1,"inH2O","Pa") # Pascal
          
      # Performance curves
      # NOTE: These coefficients are in SI UNITS
      cOOL_CAP_FT_SPEC = [[1.008993521905866, 0.006512749025457, 0.0, 0.003917565735935, -0.000222646705889, 0.0]] * num_speeds
      cOOL_EIR_FT_SPEC = [[0.429214441601141, -0.003604841598515, 0.000045783162727, 0.026490875804937, -0.000159212286878, -0.000159062656483]] * num_speeds                
      cOOL_CAP_FFLOW_SPEC = [[1, 0, 0]] * num_speeds
      
      # Mini-Split Heat Pump Heating Curve Coefficients
      # Derive coefficients from user input for capacity retention at outdoor drybulb temperature X [C].
      # Biquadratic: capacity multiplier = a + b*IAT + c*IAT^2 + d*OAT + e*OAT^2 + f*IAT*OAT
      x_A = UnitConversions.convert(cap_retention_temp,"F", "C")
      y_A = cap_retention_frac
      x_B = UnitConversions.convert(47.0,"F","C") # 47F is the rating point
      y_B = 1.0 # Maximum capacity factor is 1 at the rating point, by definition (this is maximum capacity, not nominal capacity)
      oat_slope = (y_B - y_A) / (x_B - x_A)
      oat_intercept = y_A - (x_A*oat_slope)
      
      # Coefficients for the indoor temperature relationship are retained from the BEoptDefault curve (Daikin lab data).
      iat_slope = -0.010386676170938
      iat_intercept = 0.219274275 
      
      a = oat_intercept + iat_intercept
      b = iat_slope
      c = 0
      d = oat_slope
      e = 0
      f = 0
      hEAT_CAP_FT_SPEC = [[a, b, c, d, e, f]] * num_speeds         
      
      # COP/EIR as a function of temperature
      # Generic "BEoptDefault" curves (=Daikin from lab data)            
      hEAT_EIR_FT_SPEC = [[0.966475472847719, 0.005914950101249, 0.000191201688297, -0.012965668198361, 0.000042253229429, -0.000524002558712]] * num_speeds
      
      mshp_indices = [1,3,5,9]
      
      # Cooling Coil
      c_d_cooling = 0.25
      cOOL_CLOSS_FPLR_SPEC = calc_plr_coefficients_cooling(num_speeds, seer, c_d_cooling)
      dB_rated = 80.0
      wB_rated = 67.0
      cfms_cooling, capacity_ratios_cooling, shrs_rated = calc_mshp_cfms_ton_cooling(min_cooling_capacity, max_cooling_capacity, min_cooling_airflow_rate, max_cooling_airflow_rate, num_speeds, dB_rated, wB_rated, shr)
      cooling_eirs = calc_mshp_cooling_eirs(runner, seer, fan_power, c_d_cooling, num_speeds, capacity_ratios_cooling, cfms_cooling, cOOL_EIR_FT_SPEC, cOOL_CAP_FT_SPEC)

      # Heating Coil
      c_d_heating = 0.40
      hEAT_CLOSS_FPLR_SPEC = calc_plr_coefficients_heating(num_speeds, hspf, c_d_heating)
      cfms_heating, capacity_ratios_heating = calc_mshp_cfms_ton_heating(min_heating_capacity, max_heating_capacity, min_heating_airflow_rate, max_heating_airflow_rate, num_speeds)
      heating_eirs = calc_mshp_heating_eirs(runner, hspf, fan_power, cap_retention_frac, cap_retention_temp, min_hp_temp, c_d_heating, cfms_cooling, num_speeds, capacity_ratios_heating, cfms_heating, hEAT_EIR_FT_SPEC, hEAT_CAP_FT_SPEC)

      min_plr_heat = capacity_ratios_heating[mshp_indices.min] / capacity_ratios_heating[mshp_indices.max]
      min_plr_cool = capacity_ratios_cooling[mshp_indices.min] / capacity_ratios_cooling[mshp_indices.max]
          
      # Curves
      curve_index = mshp_indices[-1]+1
      cool_cap_ft_curve = create_curve_biquadratic(model, cOOL_CAP_FT_SPEC[-1], "Cool-CAP-fT#{curve_index}", 13.88, 23.88, 18.33, 51.66)
      cool_eir_ft_curve = create_curve_biquadratic(model, cOOL_EIR_FT_SPEC[-1], "Cool-EIR-fT#{curve_index}", 13.88, 23.88, 18.33, 51.66)
      cool_eir_fplr_curve = create_curve_quadratic(model, [0.100754583, -0.131544809, 1.030916234], "Cool-EIR-fPLR#{curve_index}", min_plr_cool, 1, nil, nil, true)
      cool_plf_fplr_curve = create_curve_quadratic(model, cOOL_CLOSS_FPLR_SPEC, "Cool-PLF-fPLR#{curve_index}", 0, 1, 0.7, 1)
      heat_cap_ft_curve = create_curve_biquadratic(model, hEAT_CAP_FT_SPEC[-1], "Heat-CAP-fT#{curve_index}", -100, 100, -100, 100)
      heat_eir_ft_curve = create_curve_biquadratic(model, hEAT_EIR_FT_SPEC[-1], "Heat-EIR-fT#{curve_index}", -100, 100, -100, 100)
      heat_eir_fplr_curve = create_curve_quadratic(model, [-0.169542039, 1.167269914, 0.0], "Heat-EIR-fPLR#{curve_index}", min_plr_heat, 1, nil, nil, true)
      heat_plf_fplr_curve = create_curve_quadratic(model, hEAT_CLOSS_FPLR_SPEC, "Heat-PLF-fPLR#{curve_index}", 0, 1, 0.7, 1)
      constant_cubic_curve = create_curve_cubic_constant(model)
      defrost_eir_curve = create_curve_biquadratic(model, [0.1528, 0, 0, 0, 0, 0], "DefrostEIR", -100, 100, -100, 100)
    
      if pan_heater_power > 0    
        vrf_heating_output_var = OpenStudio::Model::OutputVariable.new("VRF Heat Pump Heating Electric Energy", model)
        vrf_heating_output_var.setName(Constants.ObjectNameMiniSplitHeatPump(unit.name.to_s) + " vrf heat energy output var")
        zone_outdoor_air_drybulb_temp_output_var = OpenStudio::Model::OutputVariable.new("Zone Outdoor Air Drybulb Temperature", model)
        zone_outdoor_air_drybulb_temp_output_var.setName(Constants.ObjectNameMiniSplitHeatPump(unit.name.to_s) + " zone outdoor air drybulb temp output var")
      end

      obj_name = Constants.ObjectNameMiniSplitHeatPump(unit.name.to_s)
    
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)
      
      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
      
        ([control_zone] + slave_zones).each do |zone|
        
            # Remove existing equipment
            remove_existing_hvac_equipment(model, runner, Constants.ObjectNameMiniSplitHeatPump, zone, false, unit)
          
            # _processSystemHeatingCoil
            
            htg_coil = OpenStudio::Model::CoilHeatingDXVariableRefrigerantFlow.new(model)
            htg_coil.setName(obj_name + " #{zone.name} heating coil")
            htg_coil.setHeatingCapacityRatioModifierFunctionofTemperatureCurve(constant_cubic_curve)
            htg_coil.setHeatingCapacityModifierFunctionofFlowFractionCurve(constant_cubic_curve)        
          
            # _processSystemCoolingCoil
            
            clg_coil = OpenStudio::Model::CoilCoolingDXVariableRefrigerantFlow.new(model)
            clg_coil.setName(obj_name + " #{zone.name} cooling coil")
            if heat_pump_capacity != Constants.SizingAuto and heat_pump_capacity != Constants.SizingAutoMaxLoad
              clg_coil.setRatedTotalCoolingCapacity(UnitConversions.convert(heat_pump_capacity,"Btu/hr","W")) # Used by HVACSizing measure
            end
            clg_coil.setRatedSensibleHeatRatio(shrs_rated[mshp_indices[-1]])
            clg_coil.setCoolingCapacityRatioModifierFunctionofTemperatureCurve(constant_cubic_curve)
            clg_coil.setCoolingCapacityModifierCurveFunctionofFlowFraction(constant_cubic_curve)
          
            # _processSystemAir
            
            vrf = OpenStudio::Model::AirConditionerVariableRefrigerantFlow.new(model)
            vrf.setName(obj_name + " #{zone.name} ac vrf")
            vrf.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
            vrf.setRatedCoolingCOP(dse / cooling_eirs[-1])
            vrf.setMinimumOutdoorTemperatureinCoolingMode(-6)
            vrf.setMaximumOutdoorTemperatureinCoolingMode(60)
            vrf.setCoolingCapacityRatioModifierFunctionofLowTemperatureCurve(cool_cap_ft_curve)    
            vrf.setCoolingEnergyInputRatioModifierFunctionofLowTemperatureCurve(cool_eir_ft_curve)
            vrf.setCoolingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve(cool_eir_fplr_curve)
            vrf.setCoolingPartLoadFractionCorrelationCurve(cool_plf_fplr_curve)
            vrf.setRatedTotalHeatingCapacitySizingRatio(1)
            vrf.setRatedHeatingCOP(dse / heating_eirs[-1])
            vrf.setMinimumOutdoorTemperatureinHeatingMode(UnitConversions.convert(min_hp_temp,"F","C"))
            vrf.setMaximumOutdoorTemperatureinHeatingMode(40)
            vrf.setHeatingCapacityRatioModifierFunctionofLowTemperatureCurve(heat_cap_ft_curve)
            vrf.setHeatingEnergyInputRatioModifierFunctionofLowTemperatureCurve(heat_eir_ft_curve)
            vrf.setHeatingPerformanceCurveOutdoorTemperatureType("DryBulbTemperature")   
            vrf.setHeatingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve(heat_eir_fplr_curve)
            vrf.setHeatingPartLoadFractionCorrelationCurve(heat_plf_fplr_curve)        
            vrf.setMinimumHeatPumpPartLoadRatio([min_plr_heat, min_plr_cool].min)
            vrf.setZoneforMasterThermostatLocation(zone)
            vrf.setMasterThermostatPriorityControlType("LoadPriority")
            vrf.setHeatPumpWasteHeatRecovery(false)
            vrf.setCrankcaseHeaterPowerperCompressor(0)
            vrf.setNumberofCompressors(1)
            vrf.setRatioofCompressorSizetoTotalCompressorCapacity(1)
            vrf.setDefrostStrategy("ReverseCycle")
            vrf.setDefrostControl("OnDemand")
            vrf.setDefrostEnergyInputRatioModifierFunctionofTemperatureCurve(defrost_eir_curve)        
            vrf.setMaximumOutdoorDrybulbTemperatureforDefrostOperation(UnitConversions.convert(max_defrost_temp,"F","C"))
            vrf.setFuelType("Electricity")
            vrf.setEquivalentPipingLengthusedforPipingCorrectionFactorinCoolingMode(0)
            vrf.setVerticalHeightusedforPipingCorrectionFactor(0)
            vrf.setPipingCorrectionFactorforHeightinCoolingModeCoefficient(0)
            vrf.setEquivalentPipingLengthusedforPipingCorrectionFactorinHeatingMode(0)

            # _processSystemFan

            fan = OpenStudio::Model::FanOnOff.new(model, model.alwaysOnDiscreteSchedule)
            fan.setName(obj_name + " #{zone.name} supply fan")
            fan.setEndUseSubcategory(Constants.EndUseHVACFan)
            fan.setFanEfficiency(dse * calculate_fan_efficiency(static, fan_power))
            fan.setPressureRise(static)
            fan.setMotorEfficiency(dse * 1.0)
            fan.setMotorInAirstreamFraction(1.0)       
            
            # _processSystemDemandSideAir
            
            tu_vrf = OpenStudio::Model::ZoneHVACTerminalUnitVariableRefrigerantFlow.new(model, clg_coil, htg_coil, fan)
            tu_vrf.setName(obj_name + " #{zone.name} zone vrf")
            tu_vrf.setTerminalUnitAvailabilityschedule(model.alwaysOnDiscreteSchedule)
            tu_vrf.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule)
            tu_vrf.setZoneTerminalUnitOnParasiticElectricEnergyUse(0)
            tu_vrf.setZoneTerminalUnitOffParasiticElectricEnergyUse(0)
            tu_vrf.setRatedTotalHeatingCapacitySizingRatio(1)
            tu_vrf.addToThermalZone(zone)
            vrf.addTerminal(tu_vrf)
            runner.registerInfo("Added '#{tu_vrf.name}' to '#{zone.name}' of #{unit.name}")        
            
            prioritize_zone_hvac(model, runner, zone)
            
            # Supplemental heat
            unless supplemental_capacity == 0.0
              supp_htg_coil = OpenStudio::Model::ZoneHVACBaseboardConvectiveElectric.new(model)
              supp_htg_coil.setName(obj_name + " #{zone.name} supp heater")
              if supplemental_capacity != Constants.SizingAuto
                supp_htg_coil.setNominalCapacity(UnitConversions.convert(supplemental_capacity,"Btu/hr","W")) # Used by HVACSizing measure
              end
              supp_htg_coil.setEfficiency(supplemental_efficiency)
              supp_htg_coil.addToThermalZone(zone)
              runner.registerInfo("Added '#{supp_htg_coil.name}' to '#{zone.name}' of #{unit.name}")     
            end
        
        end
        
        if pan_heater_power > 0

          vrf_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, vrf_heating_output_var)
          vrf_sensor.setName("#{obj_name} vrf energy sensor".gsub("|","_"))
          vrf_sensor.setKeyName(obj_name + " #{control_zone.name} ac vrf")
          
          vrf_fbsmt_sensor = nil
          slave_zones.each do |slave_zone|
            vrf_fbsmt_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, vrf_heating_output_var)
            vrf_fbsmt_sensor.setName("#{obj_name} vrf fbsmt energy sensor".gsub("|","_"))
            vrf_fbsmt_sensor.setKeyName(obj_name + " #{slave_zone.name} ac vrf")
          end
     
          equip_def = OpenStudio::Model::ElectricEquipmentDefinition.new(model)
          equip_def.setName(obj_name + " pan heater equip")
          equip = OpenStudio::Model::ElectricEquipment.new(equip_def)
          equip.setName(equip_def.name.to_s)
          equip.setSpace(control_zone.spaces[0])
          equip_def.setFractionRadiant(0)
          equip_def.setFractionLatent(0)
          equip_def.setFractionLost(1)
          equip.setSchedule(model.alwaysOnDiscreteSchedule)

          pan_heater_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(equip, "ElectricEquipment", "Electric Power Level")
          pan_heater_actuator.setName("#{obj_name} pan heater actuator".gsub("|","_"))

          tout_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, zone_outdoor_air_drybulb_temp_output_var)
          tout_sensor.setName("#{obj_name} tout sensor".gsub("|","_"))
          thermal_zones.each do |thermal_zone|
            if Geometry.is_living(thermal_zone)
              tout_sensor.setKeyName(thermal_zone.name.to_s)
              break
            end
          end

          program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
          program.setName(obj_name + " pan heater program")
          if heat_pump_capacity != Constants.SizingAuto and heat_pump_capacity != Constants.SizingAutoMaxLoad
            num_outdoor_units = (UnitConversions.convert(heat_pump_capacity,"Btu/hr","ton") / 1.5).ceil # Assume 1.5 tons max per outdoor unit
          else
            num_outdoor_units = 2
          end
          unless slave_zones.empty?
            num_outdoor_units = [num_outdoor_units, 2].max
          end
          pan_heater_power = pan_heater_power * num_outdoor_units # W
          program.addLine("Set #{pan_heater_actuator.name} = 0")
          if slave_zones.empty?
            program.addLine("Set vrf_fbsmt_sensor = 0")
            program.addLine("If #{vrf_sensor.name} > 0 || vrf_fbsmt_sensor > 0")
          else
            program.addLine("Set #{vrf_fbsmt_sensor.name} = 0")
            program.addLine("If #{vrf_sensor.name} > 0 || #{vrf_fbsmt_sensor.name} > 0")
          end          
          program.addLine("If #{tout_sensor.name} <= #{UnitConversions.convert(32.0,"F","C").round(3)}")
          program.addLine("Set #{pan_heater_actuator.name} = #{pan_heater_power}")
          program.addLine("EndIf")
          program.addLine("EndIf")
         
          program_calling_manager = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
          program_calling_manager.setName(obj_name + " pan heater program calling manager")
          program_calling_manager.setCallingPoint("BeginTimestepBeforePredictor")
          program_calling_manager.addProgram(program)
          
        end # slave_zone
      
      end # control_zone
      
      # Store is_ducted bool
      unit.setFeature(Constants.DuctedInfoMiniSplitHeatPump, is_ducted)
      
      # Store info for HVAC Sizing measure
      unit.setFeature(Constants.SizingInfoHVACCapacityRatioCooling, capacity_ratios_cooling.join(","))
      unit.setFeature(Constants.SizingInfoHVACCapacityRatioHeating, capacity_ratios_heating.join(","))
      unit.setFeature(Constants.SizingInfoHVACCoolingCFMs, cfms_cooling.join(","))
      unit.setFeature(Constants.SizingInfoHVACHeatingCFMs, cfms_heating.join(","))
      unit.setFeature(Constants.SizingInfoHVACHeatingCapacityOffset, heating_capacity_offset)
      unit.setFeature(Constants.SizingInfoHPSizedForMaxLoad, (heat_pump_capacity == Constants.SizingAutoMaxLoad))
      unit.setFeature(Constants.SizingInfoHVACSHR, shrs_rated.join(","))
      unit.setFeature(Constants.SizingInfoMSHPIndices, mshp_indices.join(","))
    
      return true
    end
    
    def self.apply_gshp() # TODO
    
    end
    
    def self.apply_room_ac(model, unit, runner, eer, shr,
                           airflow_rate, capacity)
    
      # Performance curves
      # From Frigidaire 10.7 EER unit in Winkler et. al. Lab Testing of Window ACs (2013)
      # NOTE: These coefficients are in SI UNITS
      cOOL_CAP_FT_SPEC = [0.6405, 0.01568, 0.0004531, 0.001615, -0.0001825, 0.00006614]
      cOOL_EIR_FT_SPEC = [2.287, -0.1732, 0.004745, 0.01662, 0.000484, -0.001306]
      cOOL_CAP_FFLOW_SPEC = [0.887, 0.1128, 0]
      cOOL_EIR_FFLOW_SPEC = [1.763, -0.6081, 0]
      cOOL_PLF_FPLR = [0.78, 0.22, 0]
      cfms_ton_rated = [312]    # medium speed
    
      roomac_cap_ft_curve = create_curve_biquadratic(model, cOOL_CAP_FT_SPEC, "RoomAC-Cap-fT", 0, 100, 0, 100)
      roomac_cap_fff_curve = create_curve_quadratic(model, cOOL_CAP_FFLOW_SPEC, "RoomAC-Cap-fFF", 0, 2, 0, 2)
      roomac_eir_ft_curve = create_curve_biquadratic(model, cOOL_EIR_FT_SPEC, "RoomAC-EIR-fT", 0, 100, 0, 100)
      roomcac_eir_fff_curve = create_curve_quadratic(model, cOOL_EIR_FFLOW_SPEC, "RoomAC-EIR-fFF", 0, 2, 0, 2)
      roomac_plf_fplr_curve = create_curve_quadratic(model, cOOL_PLF_FPLR, "RoomAC-PLF-fPLR", 0, 1, 0, 1)
      
      obj_name = Constants.ObjectNameRoomAirConditioner(unit.name.to_s)
      
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
    
        next unless Geometry.zone_is_above_grade(control_zone)

        # Remove existing equipment
        remove_existing_hvac_equipment(model, runner, Constants.ObjectNameRoomAirConditioner, control_zone, false, unit)
      
        # _processSystemRoomAC
      
        clg_coil = OpenStudio::Model::CoilCoolingDXSingleSpeed.new(model, model.alwaysOnDiscreteSchedule, roomac_cap_ft_curve, roomac_cap_fff_curve, roomac_eir_ft_curve, roomcac_eir_fff_curve, roomac_plf_fplr_curve)
        clg_coil.setName(obj_name + " cooling coil")
        if capacity != Constants.SizingAuto
          clg_coil.setRatedTotalCoolingCapacity(UnitConversions.convert(capacity,"Btu/hr","W")) # Used by HVACSizing measure
        end
        clg_coil.setRatedSensibleHeatRatio(shr)
        clg_coil.setRatedCOP(OpenStudio::OptionalDouble.new(UnitConversions.convert(eer, "Btu/hr", "W")))
        clg_coil.setRatedEvaporatorFanPowerPerVolumeFlowRate(OpenStudio::OptionalDouble.new(773.3))
        clg_coil.setEvaporativeCondenserEffectiveness(OpenStudio::OptionalDouble.new(0.9))
        clg_coil.setMaximumOutdoorDryBulbTemperatureForCrankcaseHeaterOperation(OpenStudio::OptionalDouble.new(10))
        clg_coil.setBasinHeaterSetpointTemperature(OpenStudio::OptionalDouble.new(2))
        
        fan = OpenStudio::Model::FanOnOff.new(model, model.alwaysOnDiscreteSchedule)
        fan.setName(obj_name + " supply fan")
        fan.setEndUseSubcategory(Constants.EndUseHVACFan)
        fan.setFanEfficiency(1)
        fan.setPressureRise(0)
        fan.setMotorEfficiency(1)
        fan.setMotorInAirstreamFraction(0)
        
        htg_coil = OpenStudio::Model::CoilHeatingElectric.new(model, model.alwaysOffDiscreteSchedule())
        htg_coil.setName(obj_name + " always off heating coil")
        
        ptac = OpenStudio::Model::ZoneHVACPackagedTerminalAirConditioner.new(model, model.alwaysOnDiscreteSchedule, fan, htg_coil, clg_coil)
        ptac.setName(obj_name + " zone ptac")
        ptac.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule)
        ptac.addToThermalZone(control_zone)
        runner.registerInfo("Added '#{ptac.name}' to '#{control_zone.name}' of #{unit.name}")
              
        prioritize_zone_hvac(model, runner, control_zone)
      
        slave_zones.each do |slave_zone|

          # Remove existing equipment
          remove_existing_hvac_equipment(model, runner, Constants.ObjectNameRoomAirConditioner, slave_zone, false, unit)

          prioritize_zone_hvac(model, runner, slave_zone)
          
        end # slave_zone
      
      end # control_zone
      
      # Store info for HVAC Sizing measure
      unit.setFeature(Constants.SizingInfoHVACCoolingCFMs, airflow_rate.to_s)
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonCooling, cfms_ton_rated.join(","))
      
      return true
    end
    
    def self.apply_furnace(model, unit, runner, fuel_type, afue,
                           capacity, fan_power_installed, dse)
    
      # _processAirSystem
      
      static = UnitConversions.convert(0.5,"inH2O","Pa") # Pascal

      hir = get_furnace_hir(afue)

      # Parasitic Electricity (Source: DOE. (2007). Technical Support Document: Energy Efficiency Program for Consumer Products: "Energy Conservation Standards for Residential Furnaces and Boilers". www.eere.energy.gov/buildings/appliance_standards/residential/furnaces_boilers.html)
      #             FurnaceParasiticElecDict = {Constants.FuelTypeGas     :  76, # W during operation
      #                                         Constants.FuelTypeOil     : 220}
      #             aux_elec = FurnaceParasiticElecDict[fuel_type]
      aux_elec = 0.0 # set to zero until we figure out a way to distribute to the correct end uses (DOE-2 limitation?)    

      obj_name = Constants.ObjectNameFurnace(fuel_type, unit.name.to_s)
    
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
      
        # Remove existing equipment
        clg_coil, perf = remove_existing_hvac_equipment(model, runner, Constants.ObjectNameFurnace, control_zone, true, unit)
        
        # _processSystemHeatingCoil

        if fuel_type == Constants.FuelTypeElectric
          htg_coil = OpenStudio::Model::CoilHeatingElectric.new(model)
          htg_coil.setEfficiency(dse / hir)
        else
          htg_coil = OpenStudio::Model::CoilHeatingGas.new(model)
          htg_coil.setGasBurnerEfficiency(dse / hir)
          htg_coil.setParasiticElectricLoad(aux_elec) # set to zero until we figure out a way to distribute to the correct end uses (DOE-2 limitation?)
          htg_coil.setParasiticGasLoad(0)
          htg_coil.setFuelType(HelperMethods.eplus_fuel_map(fuel_type))
        end
        htg_coil.setName(obj_name + " heating coil")
        if capacity != Constants.SizingAuto
          htg_coil.setNominalCapacity(UnitConversions.convert(capacity,"Btu/hr","W")) # Used by HVACSizing measure
        end
        
        # _processSystemFan
        if not clg_coil.nil?
          obj_name = Constants.ObjectNameFurnaceAndCentralAirConditioner(fuel_type, unit.name.to_s)
        end

        fan = OpenStudio::Model::FanOnOff.new(model, model.alwaysOnDiscreteSchedule)
        fan.setName(obj_name + " supply fan")
        fan.setEndUseSubcategory(Constants.EndUseHVACFan)
        fan.setFanEfficiency(dse * UnitConversions.convert(static / fan_power_installed,"cfm","m^3/s")) # Overall Efficiency of the Supply Fan, Motor and Drive
        fan.setPressureRise(static)
        fan.setMotorEfficiency(dse * 1.0)
        fan.setMotorInAirstreamFraction(1.0)  
      
        # _processSystemAir
        
        air_loop_unitary = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
        air_loop_unitary.setName(obj_name + " unitary system")
        air_loop_unitary.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
        air_loop_unitary.setHeatingCoil(htg_coil)
        if not clg_coil.nil?
          # Add the existing DX central air back in
          air_loop_unitary.setCoolingCoil(clg_coil)
        else
          air_loop_unitary.setSupplyAirFlowRateDuringCoolingOperation(0.0000001) # this is when there is no cooling present
        end
        if not perf.nil?
          air_loop_unitary.setDesignSpecificationMultispeedObject(perf)
        end
        air_loop_unitary.setSupplyFan(fan)
        air_loop_unitary.setFanPlacement("BlowThrough")
        air_loop_unitary.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule)
        air_loop_unitary.setMaximumSupplyAirTemperature(UnitConversions.convert(120.0,"F","C"))      
        air_loop_unitary.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(0)

        air_loop = OpenStudio::Model::AirLoopHVAC.new(model)
        air_loop.setName(obj_name + " central air system")
        air_supply_inlet_node = air_loop.supplyInletNode
        air_supply_outlet_node = air_loop.supplyOutletNode
        air_demand_inlet_node = air_loop.demandInletNode
        air_demand_outlet_node = air_loop.demandOutletNode

        air_loop_unitary.addToNode(air_supply_inlet_node)

        runner.registerInfo("Added '#{fan.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        runner.registerInfo("Added '#{htg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        unless clg_coil.nil?
          runner.registerInfo("Added '#{clg_coil.name}' to '#{air_loop_unitary.name}' of '#{air_loop.name}'")
        end

        air_loop_unitary.setControllingZoneorThermostatLocation(control_zone)

        # _processSystemDemandSideAir
        # Demand Side

        # Supply Air
        zone_splitter = air_loop.zoneSplitter
        zone_splitter.setName(obj_name + " zone splitter")
        
        zone_mixer = air_loop.zoneMixer
        zone_mixer.setName(obj_name + " zone mixer")

        diffuser_living = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
        diffuser_living.setName(obj_name + " #{control_zone.name} direct air")
        air_loop.addBranchForZone(control_zone, diffuser_living.to_StraightComponent)

        air_loop.addBranchForZone(control_zone)
        runner.registerInfo("Added '#{air_loop.name}' to '#{control_zone.name}' of #{unit.name}")
      
        prioritize_zone_hvac(model, runner, control_zone)
      
        slave_zones.each do |slave_zone|
        
          # Remove existing equipment
          remove_existing_hvac_equipment(model, runner, Constants.ObjectNameFurnace, slave_zone, false, unit)
        
          diffuser_fbsmt = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
          diffuser_fbsmt.setName(obj_name + " #{slave_zone.name} direct air")
          air_loop.addBranchForZone(slave_zone, diffuser_fbsmt.to_StraightComponent)

          air_loop.addBranchForZone(slave_zone)
          runner.registerInfo("Added '#{air_loop.name}' to '#{slave_zone.name}' of #{unit.name}")
        
          prioritize_zone_hvac(model, runner, slave_zone)
        
        end    
      
      end
    
      return true
    end
    
    def self.apply_boiler() # TODO
    
    end
    
    def self.apply_electric_baseboard(model, unit, runner, efficiency, capacity)
    
      obj_name = Constants.ObjectNameElectricBaseboard(unit.name.to_s)
      
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
    
        ([control_zone] + slave_zones).each do |zone|
        
          # Remove existing equipment
          remove_existing_hvac_equipment(model, runner, Constants.ObjectNameElectricBaseboard, zone, false, unit)
        
          htg_coil = OpenStudio::Model::ZoneHVACBaseboardConvectiveElectric.new(model)
          htg_coil.setName(obj_name + " #{zone.name} convective electric")
          if capacity != Constants.SizingAuto
              htg_coil.setNominalCapacity(UnitConversions.convert(capacity,"Btu/hr","W")) # Used by HVACSizing measure
          end
          htg_coil.setEfficiency(efficiency)

          htg_coil.addToThermalZone(zone)
          runner.registerInfo("Added '#{htg_coil.name}' to '#{zone.name}' of #{unit.name}")
         
          prioritize_zone_hvac(model, runner, zone)
          
        end
        
      end
    
      return true
    end
    
    def self.apply_unit_heater(model, unit, runner, fuel_type,
                               efficiency, capacity, fan_power,
                               airflow_rate)
    
      if fan_power > 0 and airflow_rate == 0
        runner.registerError("If Fan Power > 0, then Airflow Rate cannot be zero.")
        return false
      end
      
      static = UnitConversions.convert(0.5,"inH2O","Pa") # Pascal
    
      obj_name = Constants.ObjectNameUnitHeater(fuel_type, unit.name.to_s)
    
      thermal_zones = Geometry.get_thermal_zones_from_spaces(unit.spaces)

      control_slave_zones_hash = get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash.each do |control_zone, slave_zones|
      
        ([control_zone] + slave_zones).each do |zone|
      
          # Remove existing equipment
          remove_existing_hvac_equipment(model, runner, Constants.ObjectNameUnitHeater, zone, true, unit)
          
          # _processSystemHeatingCoil

          htg_coil = OpenStudio::Model::CoilHeatingGas.new(model)
          htg_coil.setName(obj_name + " heating coil")
          htg_coil.setGasBurnerEfficiency(efficiency)
          if capacity != Constants.SizingAuto
            htg_coil.setNominalCapacity(UnitConversions.convert(capacity,"Btu/hr","W")) # Used by HVACSizing measure
          end
          htg_coil.setParasiticElectricLoad(0.0)
          htg_coil.setParasiticGasLoad(0)
          htg_coil.setFuelType(HelperMethods.eplus_fuel_map(fuel_type))
          
          
          fan = OpenStudio::Model::FanOnOff.new(model, model.alwaysOnDiscreteSchedule)
          fan.setName(obj_name + " fan")
          fan.setEndUseSubcategory(Constants.EndUseHVACFan)
          if fan_power > 0
            fan.setFanEfficiency(UnitConversions.convert(static / fan_power,"cfm","m^3/s")) # Overall Efficiency of the Fan, Motor and Drive
            fan.setPressureRise(static)
            fan.setMotorEfficiency(1.0)
            fan.setMotorInAirstreamFraction(1.0)  
          else
            fan.setFanEfficiency(1) # Overall Efficiency of the Fan, Motor and Drive
            fan.setPressureRise(0)
            fan.setMotorEfficiency(1.0)
            fan.setMotorInAirstreamFraction(1.0)  
          end
          
        
          # _processSystemAir
          
          unitary_system = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
          unitary_system.setName(obj_name + " unitary system")
          unitary_system.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
          unitary_system.setHeatingCoil(htg_coil)
          unitary_system.setSupplyAirFlowRateMethodDuringCoolingOperation("SupplyAirFlowRate")
          unitary_system.setSupplyAirFlowRateDuringCoolingOperation(0.00001)
          unitary_system.setSupplyFan(fan)
          unitary_system.setFanPlacement("BlowThrough")
          unitary_system.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule)
          unitary_system.setMaximumSupplyAirTemperature(UnitConversions.convert(120.0,"F","C"))      
          unitary_system.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(0)

          #unitary_system.addToNode(air_supply_inlet_node)

          runner.registerInfo("Added '#{fan.name}' to '#{unitary_system.name}''")
          runner.registerInfo("Added '#{htg_coil.name}' to '#{unitary_system.name}'")

          unitary_system.setControllingZoneorThermostatLocation(zone)
          unitary_system.addToThermalZone(zone)

          prioritize_zone_hvac(model, runner, zone)
          
        end
      
      end
      
      unit.setFeature(Constants.SizingInfoHVACRatedCFMperTonHeating, airflow_rate.to_s)
    
      return true
    end
    
    def self.apply_heating_setpoints() # TODO
    
    end
    
    def self.apply_cooling_setpoints() # TODO
    
    end
    
    def self.apply_dehumidifier() # TODO
    
    end
    
    def self.apply_ceiling_fans() # TODO
    
    end
    
    def self.apply_sizing() # TODO (in separate file...)
    
    end
    
    private

    def self.calc_EIR_from_COP(cop, supplyFanPower_Rated)
      return UnitConversions.convert((UnitConversions.convert(1,"Btu","Wh") + supplyFanPower_Rated * 0.03333) / cop - supplyFanPower_Rated * 0.03333,"Wh","Btu")
    end
  
    def self.calc_EIR_from_EER(eer, supplyFanPower_Rated)
      return UnitConversions.convert((1 - UnitConversions.convert(supplyFanPower_Rated * 0.03333,"Wh","Btu")) / eer - supplyFanPower_Rated * 0.03333,"Wh","Btu")
    end
    
    def self.calc_cfms_ton_rated(rated_airflow_rate, fan_speed_ratios, capacity_ratios)
      array = []
      fan_speed_ratios.each_with_index do |fanspeed_ratio, i|
        capacity_ratio = capacity_ratios[i]
        array << fanspeed_ratio * rated_airflow_rate / capacity_ratio
      end
      return array
    end      
    
    def self.create_curve_biquadratic_constant(model)
      const_biquadratic = OpenStudio::Model::CurveBiquadratic.new(model)
      const_biquadratic.setName("ConstantBiquadratic")
      const_biquadratic.setCoefficient1Constant(1)
      const_biquadratic.setCoefficient2x(0)
      const_biquadratic.setCoefficient3xPOW2(0)
      const_biquadratic.setCoefficient4y(0)
      const_biquadratic.setCoefficient5yPOW2(0)
      const_biquadratic.setCoefficient6xTIMESY(0)
      const_biquadratic.setMinimumValueofx(-100)
      const_biquadratic.setMaximumValueofx(100)
      const_biquadratic.setMinimumValueofy(-100)
      const_biquadratic.setMaximumValueofy(100)   
      return const_biquadratic
    end
    
    def self.create_curve_cubic_constant(model)
      constant_cubic = OpenStudio::Model::CurveCubic.new(model)
      constant_cubic.setName("ConstantCubic")
      constant_cubic.setCoefficient1Constant(1)
      constant_cubic.setCoefficient2x(0)
      constant_cubic.setCoefficient3xPOW2(0)
      constant_cubic.setCoefficient4xPOW3(0)
      constant_cubic.setMinimumValueofx(-100)
      constant_cubic.setMaximumValueofx(100)
      return constant_cubic
    end

    def self.convert_curve_biquadratic(coeff, ip_to_si)
      if ip_to_si
        # Convert IP curves to SI curves
        si_coeff = []
        si_coeff << coeff[0] + 32.0 * (coeff[1] + coeff[3]) + 1024.0 * (coeff[2] + coeff[4] + coeff[5])
        si_coeff << 9.0 / 5.0 * coeff[1] + 576.0 / 5.0 * coeff[2] + 288.0 / 5.0 * coeff[5]
        si_coeff << 81.0 / 25.0 * coeff[2]
        si_coeff << 9.0 / 5.0 * coeff[3] + 576.0 / 5.0 * coeff[4] + 288.0 / 5.0 * coeff[5]
        si_coeff << 81.0 / 25.0 * coeff[4]
        si_coeff << 81.0 / 25.0 * coeff[5]        
        return si_coeff
      else
        # Convert SI curves to IP curves
        ip_coeff = []
        ip_coeff << coeff[0] - 160.0/9.0 * (coeff[1] + coeff[3]) + 25600.0/81.0 * (coeff[2] + coeff[4] + coeff[5])
        ip_coeff << 5.0/9.0 * (coeff[1] - 320.0/9.0 * coeff[2] - 160.0/9.0 * coeff[5])
        ip_coeff << 25.0/81.0 * coeff[2]
        ip_coeff << 5.0/9.0 * (coeff[3] - 320.0/9.0 * coeff[4] - 160.0/9.0 * coeff[5])
        ip_coeff << 25.0/81.0 * coeff[4]
        ip_coeff << 25.0/81.0 * coeff[5]
        return ip_coeff
      end
  end
  
  def self.convert_curve_gshp(coeff, gshp_to_biquadratic)
      m1 = 32 - 273.15 * 1.8
      m2 = 283 * 1.8
      if gshp_to_biquadratic
        biq_coeff = []
        biq_coeff << coeff[0] - m1 * ((coeff[1] + coeff[2]) / m2)
        biq_coeff << coeff[1] / m2
        biq_coeff << 0
        biq_coeff << coeff[2] / m2
        biq_coeff << 0
        biq_coeff << 0
        return biq_coeff
      else
        gsph_coeff = []
        gsph_coeff << coeff[0] + m1 * (coeff[1] + coeff[3])
        gsph_coeff << m2 * coeff[1]
        gsph_coeff << m2 * coeff[3]
        gsph_coeff << 0
        gsph_coeff << 0
        return gsph_coeff
      end
    end
    
    def self.create_curve_biquadratic(model, coeff, name, minX, maxX, minY, maxY)
      curve = OpenStudio::Model::CurveBiquadratic.new(model)
      curve.setName(name)
      curve.setCoefficient1Constant(coeff[0])
      curve.setCoefficient2x(coeff[1])
      curve.setCoefficient3xPOW2(coeff[2])
      curve.setCoefficient4y(coeff[3])
      curve.setCoefficient5yPOW2(coeff[4])
      curve.setCoefficient6xTIMESY(coeff[5])
      curve.setMinimumValueofx(minX)
      curve.setMaximumValueofx(maxX)
      curve.setMinimumValueofy(minY)
      curve.setMaximumValueofy(maxY)
      return curve
    end
    
    def self.create_curve_bicubic(model, coeff, name, minX, maxX, minY, maxY)
      curve = OpenStudio::Model::CurveBicubic.new(model)
      curve.setName(name)
      curve.setCoefficient1Constant(coeff[0])
      curve.setCoefficient2x(coeff[1])
      curve.setCoefficient3xPOW2(coeff[2])
      curve.setCoefficient4y(coeff[3])
      curve.setCoefficient5yPOW2(coeff[4])
      curve.setCoefficient6xTIMESY(coeff[5])
      curve.setCoefficient7xPOW3(coeff[6])
      curve.setCoefficient8yPOW3(coeff[7])
      curve.setCoefficient9xPOW2TIMESY(coeff[8])
      curve.setCoefficient10xTIMESYPOW2(coeff[9])
      curve.setMinimumValueofx(minX)
      curve.setMaximumValueofx(maxX)
      curve.setMinimumValueofy(minY)
      curve.setMaximumValueofy(maxY)
      return curve
    end
    
    def self.create_curve_quadratic(model, coeff, name, minX, maxX, minY, maxY, is_dimensionless=false)
      curve = OpenStudio::Model::CurveQuadratic.new(model)
      curve.setName(name)
      curve.setCoefficient1Constant(coeff[0])
      curve.setCoefficient2x(coeff[1])
      curve.setCoefficient3xPOW2(coeff[2])
      curve.setMinimumValueofx(minX)
      curve.setMaximumValueofx(maxX)
      if not minY.nil?
        curve.setMinimumCurveOutput(minY)
      end
      if not maxY.nil?
        curve.setMaximumCurveOutput(maxY)
      end
      if is_dimensionless
        curve.setInputUnitTypeforX("Dimensionless")
        curve.setOutputUnitType("Dimensionless")
      end
      return curve
    end
    
    def self.create_curve_cubic(model, coeff, name, minX, maxX, minY, maxY)    
      curve = OpenStudio::Model::CurveCubic.new(model)
      curve.setName(name)
      curve.setCoefficient1Constant(coeff[0])
      curve.setCoefficient2x(coeff[1])
      curve.setCoefficient3xPOW2(coeff[2])
      curve.setCoefficient4xPOW3(coeff[3])
      curve.setMinimumValueofx(minX)
      curve.setMaximumValueofx(maxX)
      curve.setMinimumCurveOutput(minY)
      curve.setMaximumCurveOutput(maxY)
      return curve
    end
    
    def self.create_curve_exponent(model, coeff, name, minX, maxX)
      curve = OpenStudio::Model::CurveExponent.new(model)
      curve.setName(name)
      curve.setCoefficient1Constant(coeff[0])
      curve.setCoefficient2Constant(coeff[1])
      curve.setCoefficient3Constant(coeff[2])
      curve.setMinimumValueofx(minX)
      curve.setMaximumValueofx(maxX)
      return curve
    end
      
    def self.calc_coil_stage_data_cooling(model, outputCapacity, num_speeds, cooling_eirs, shrs_rated_gross, cOOL_CAP_FT_SPEC, cOOL_EIR_FT_SPEC, cOOL_CLOSS_FPLR_SPEC, cOOL_CAP_FFLOW_SPEC, cOOL_EIR_FFLOW_SPEC, distributionSystemEfficiency)

      const_biquadratic = self.create_curve_biquadratic_constant(model)
    
      clg_coil_stage_data = []
      (0...num_speeds).to_a.each do |speed|
      
        cool_cap_ft_curve = self.create_curve_biquadratic(model, self.convert_curve_biquadratic(cOOL_CAP_FT_SPEC[speed], true), "Cool-Cap-fT#{speed+1}", 13.88, 23.88, 18.33, 51.66)
        cool_eir_ft_curve = self.create_curve_biquadratic(model, self.convert_curve_biquadratic(cOOL_EIR_FT_SPEC[speed], true), "Cool-EIR-fT#{speed+1}", 13.88, 23.88, 18.33, 51.66)
        cool_plf_fplr_curve = self.create_curve_quadratic(model, cOOL_CLOSS_FPLR_SPEC[speed], "Cool-PLF-fPLR#{speed+1}", 0, 1, 0.7, 1)
        cool_cap_fff_curve = self.create_curve_quadratic(model, cOOL_CAP_FFLOW_SPEC[speed], "Cool-Cap-fFF#{speed+1}", 0, 2, 0, 2)
        cool_eir_fff_curve = self.create_curve_quadratic(model, cOOL_EIR_FFLOW_SPEC[speed], "Cool-EIR-fFF#{speed+1}", 0, 2, 0, 2)

        stage_data = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model, 
                                                                             cool_cap_ft_curve, 
                                                                             cool_cap_fff_curve, 
                                                                             cool_eir_ft_curve, 
                                                                             cool_eir_fff_curve, 
                                                                             cool_plf_fplr_curve, 
                                                                             const_biquadratic)
        if outputCapacity != Constants.SizingAuto and outputCapacity != Constants.SizingAutoMaxLoad
          stage_data.setGrossRatedTotalCoolingCapacity(UnitConversions.convert(outputCapacity,"Btu/hr","W")) # Used by HVACSizing measure
        end
        stage_data.setGrossRatedSensibleHeatRatio(shrs_rated_gross[speed])
        stage_data.setGrossRatedCoolingCOP(distributionSystemEfficiency / cooling_eirs[speed])
        stage_data.setNominalTimeforCondensateRemovaltoBegin(1000)
        stage_data.setRatioofInitialMoistureEvaporationRateandSteadyStateLatentCapacity(1.5)
        stage_data.setMaximumCyclingRate(3)
        stage_data.setLatentCapacityTimeConstant(45)
        stage_data.setRatedWasteHeatFractionofPowerInput(0.2)
        clg_coil_stage_data[speed] = stage_data
      end
      return clg_coil_stage_data
    end
      
    def self.calc_coil_stage_data_heating(model, outputCapacity, num_speeds, heating_eirs, hEAT_CAP_FT_SPEC, hEAT_EIR_FT_SPEC, hEAT_CLOSS_FPLR_SPEC, hEAT_CAP_FFLOW_SPEC, hEAT_EIR_FFLOW_SPEC, distributionSystemEfficiency)
    
      const_biquadratic = self.create_curve_biquadratic_constant(model)
    
      htg_coil_stage_data = []
      # Loop through speeds to create curves for each speed
      (0...num_speeds).to_a.each do |speed|

        hp_heat_cap_ft_curve = self.create_curve_biquadratic(model, self.convert_curve_biquadratic(hEAT_CAP_FT_SPEC[speed], true), "HP_Heat-Cap-fT#{speed+1}", -100, 100, -100, 100)
        hp_heat_eir_ft_curve = self.create_curve_biquadratic(model, self.convert_curve_biquadratic(hEAT_EIR_FT_SPEC[speed], true), "HP_Heat-EIR-fT#{speed+1}", -100, 100, -100, 100)
        hp_heat_plf_fplr_curve = self.create_curve_quadratic(model, hEAT_CLOSS_FPLR_SPEC[speed], "HP_Heat-PLF-fPLR#{speed+1}", 0, 1, 0.7, 1)
        hp_heat_cap_fff_curve = self.create_curve_quadratic(model, hEAT_CAP_FFLOW_SPEC[speed], "HP_Heat-CAP-fFF#{speed+1}", 0, 2, 0, 2)
        hp_heat_eir_fff_curve = self.create_curve_quadratic(model, hEAT_EIR_FFLOW_SPEC[speed], "HP_Heat-EIR-fFF#{speed+1}", 0, 2, 0, 2)
      
        stage_data = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model, 
                                                                             hp_heat_cap_ft_curve, 
                                                                             hp_heat_cap_fff_curve, 
                                                                             hp_heat_eir_ft_curve, 
                                                                             hp_heat_eir_fff_curve, 
                                                                             hp_heat_plf_fplr_curve, 
                                                                             const_biquadratic)
        if outputCapacity != Constants.SizingAuto and outputCapacity != Constants.SizingAutoMaxLoad
          stage_data.setGrossRatedHeatingCapacity(UnitConversions.convert(outputCapacity,"Btu/hr","W")) # Used by HVACSizing measure
        end   
        stage_data.setGrossRatedHeatingCOP(distributionSystemEfficiency / heating_eirs[speed])
        stage_data.setRatedWasteHeatFractionofPowerInput(0.2)
        htg_coil_stage_data[speed] = stage_data
      end
      return htg_coil_stage_data
    end
    
    def self.calc_cooling_eirs(num_speeds, coolingEER, supplyFanPower_Rated)
      cooling_eirs = []
      (0...num_speeds).to_a.each do |speed|
        eir = calc_EIR_from_EER(coolingEER[speed], supplyFanPower_Rated)
        cooling_eirs << eir
      end
      return cooling_eirs
    end
    
    def self.calc_heating_eirs(num_speeds, heatingCOP, supplyFanPower_Rated)
      heating_eirs = []
      (0...num_speeds).to_a.each do |speed|
        eir = calc_EIR_from_COP(heatingCOP[speed], supplyFanPower_Rated)
        heating_eirs << eir
      end
      return heating_eirs
    end
    
    def self.calc_shrs_rated_gross(num_speeds, shr_Rated_Net, supplyFanPower_Rated, cfms_ton_rated)
    
      # Convert SHRs from net to gross
      shrs_rated_gross = []
      (0...num_speeds).to_a.each do |speed|

        qtot_net_nominal = 12000.0
        qsens_net_nominal = qtot_net_nominal * shr_Rated_Net[speed]
        qtot_gross_nominal = qtot_net_nominal + UnitConversions.convert(cfms_ton_rated[speed] * supplyFanPower_Rated,"Wh","Btu")
        qsens_gross_nominal = qsens_net_nominal + UnitConversions.convert(cfms_ton_rated[speed] * supplyFanPower_Rated,"Wh","Btu")
        shrs_rated_gross << (qsens_gross_nominal / qtot_gross_nominal)

        # Make sure SHR's are in valid range based on E+ model limits.
        # The following correlation was developed by Jon Winkler to test for maximum allowed SHR based on the 300 - 450 cfm/ton limits in E+
        maxSHR = 0.3821066 + 0.001050652 * cfms_ton_rated[speed] - 0.01
        shrs_rated_gross[speed] = [shrs_rated_gross[speed], maxSHR].min
        minSHR = 0.60   # Approximate minimum SHR such that an ADP exists
        shrs_rated_gross[speed] = [shrs_rated_gross[speed], minSHR].max
      end
      
      return shrs_rated_gross
    
    end
    
    def self.calc_plr_coefficients_cooling(num_speeds, coolingSEER, c_d=nil)
      if c_d.nil?
        c_d = self.get_c_d_cooling(num_speeds, coolingSEER)
      end
      return [(1.0 - c_d), c_d, 0.0] # Linear part load model
    end
    
    def self.calc_plr_coefficients_heating(num_speeds, heatingHSPF, c_d=nil)
      if c_d.nil?
        c_d = self.get_c_d_heating(num_speeds, heatingHSPF)
      end
      return [(1 - c_d), c_d, 0] # Linear part load model
    end
    
    def self.get_c_d_cooling(num_speeds, coolingSEER)
      # Degradation coefficient for cooling
      if num_speeds == 1
        if coolingSEER < 13.0
          return 0.20
        else
          return 0.07
        end
      elsif num_speeds == 2
        return 0.11
      elsif num_speeds == 4
        return 0.25
      end
    end
    
    def self.get_c_d_heating(num_speeds, heatingHSPF)
      # Degradation coefficient for heating
      if num_speeds == 1
        if heatingHSPF < 7.0
          return 0.20
        else
          return 0.11
        end
      elsif num_speeds == 2
        return 0.11
      elsif num_speeds == 4
        return 0.24
      end
    end
    
    def self.get_boiler_curve(model, isCondensing)
      if isCondensing
        return create_curve_biquadratic(model, [1.058343061, -0.052650153, -0.0087272, -0.001742217, 0.00000333715, 0.000513723], "CondensingBoilerEff", 0.2, 1.0, 30.0, 85.0)
      else
        return create_curve_bicubic(model, [1.111720116, 0.078614078, -0.400425756, 0.0, -0.000156783, 0.009384599, 0.234257955, 1.32927e-06, -0.004446701, -1.22498e-05], "NonCondensingBoilerEff", 0.1, 1.0, 20.0, 80.0)
      end
    end
  
    def self.calculate_fan_efficiency(static, fan_power)
      return UnitConversions.convert(static / fan_power,"cfm","m^3/s") # Overall Efficiency of the Supply Fan, Motor and Drive
    end

    def self.get_furnace_hir(afue)
      # Based on DOE2 Volume 5 Compliance Analysis manual.
      # This is not used until we have a better way of disaggregating AFUE
      # if afue <= 0.835:
      #     hir = 1 / (0.2907 * afue + 0.5787)
      # else:
      #     hir = 1 / (1.1116 * afue - 0.098185)

      hir = 1.0 / afue
      return hir
    end  
  
    def self.get_control_and_slave_zones(thermal_zones)
      control_slave_zones_hash = {}
      finished_above_grade_zones, finished_below_grade_zones = Geometry.get_finished_above_and_below_grade_zones(thermal_zones)
      control_zone = nil
      slave_zones = []
      [finished_above_grade_zones, finished_below_grade_zones].each do |finished_zones| # Preference to above-grade zone as control zone
        finished_zones.each do |finished_zone|
          if control_zone.nil?
            control_zone = finished_zone
          else
            slave_zones << finished_zone
          end
        end
      end
      unless control_zone.nil?
        control_slave_zones_hash[control_zone] = slave_zones
      end
      return control_slave_zones_hash
    end
  
    def self.existing_cooling_equipment(model, runner, thermal_zone)
      # Returns a list of cooling equipment objects
      cooling_equipment = []
      if self.has_ashp(model, runner, thermal_zone)
        runner.registerInfo("Found air source heat pump in #{thermal_zone.name}.")
        system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
        cooling_equipment << system
      end
      if self.has_central_ac(model, runner, thermal_zone)
        runner.registerInfo("Found central air conditioner in #{thermal_zone.name}.")
        system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
        cooling_equipment << system
      end
      if self.has_room_ac(model, runner, thermal_zone)
        runner.registerInfo("Found room air conditioner in #{thermal_zone.name}.")
        ptac = self.get_ptac(model, runner, thermal_zone)
        cooling_equipment << ptac
      end
      if self.has_mshp(model, runner, thermal_zone)
        runner.registerInfo("Found mini split heat pump in #{thermal_zone.name}.")
        vrf = self.get_vrf(model, runner, thermal_zone)
        vrf.terminals.each do |terminal|
          cooling_equipment << terminal
        end
      end
      if self.has_gshp(model, runner, thermal_zone)
        system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
        runner.registerInfo("Found ground source heat pump in #{thermal_zone.name}.")
        cooling_equipment << system
      end
      return cooling_equipment
    end
    
    def self.existing_heating_equipment(model, runner, thermal_zone)
      # Returns a list of heating equipment objects
      heating_equipment = []
      if self.has_ashp(model, runner, thermal_zone)
        runner.registerInfo("Found air source heat pump in #{thermal_zone.name}.")
        system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
        heating_equipment << system
      end
      if self.has_furnace(model, runner, thermal_zone)
        runner.registerInfo("Found furnace in #{thermal_zone.name}.")
        system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
        heating_equipment << system
      end
      if self.has_boiler(model, runner, thermal_zone)
        runner.registerInfo("Found boiler serving #{thermal_zone.name}.")
        baseboard = self.get_baseboard_water(model, runner, thermal_zone)
        heating_equipment << baseboard
      end
      if self.has_electric_baseboard(model, runner, thermal_zone)
        runner.registerInfo("Found electric baseboard in #{thermal_zone.name}.")
        baseboard = self.get_baseboard_electric(model, runner, thermal_zone)
        heating_equipment << baseboard
      end
      if self.has_mshp(model, runner, thermal_zone)
        runner.registerInfo("Found mini split heat pump in #{thermal_zone.name}.")
        vrf = self.get_vrf(model, runner, thermal_zone)
        vrf.terminals.each do |terminal|
          heating_equipment << terminal
        end
      end
      if self.has_gshp(model, runner, thermal_zone)
        runner.registerInfo("Found ground source heat pump in #{thermal_zone.name}.")
        system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
        heating_equipment << system
      end
      if self.has_unit_heater(model, runner, thermal_zone)
        runner.registerInfo("Found unit heater in #{thermal_zone.name}.")
        system, clg_coil, htg_coil = self.get_unitary_system_zone_hvac(model, runner, thermal_zone)
        heating_equipment << system
      end
      return heating_equipment
    end
    
    def self.get_coils_from_hvac_equip(hvac_equip)
      # Returns the clg coil, htg coil, and supp htg coil as applicable
      clg_coil = nil
      htg_coil = nil
      supp_htg_coil = nil
      if hvac_equip.is_a? OpenStudio::Model::AirLoopHVACUnitarySystem
        htg_coil = get_coil_from_hvac_component(hvac_equip.heatingCoil)
        clg_coil = get_coil_from_hvac_component(hvac_equip.coolingCoil)
        supp_htg_coil = get_coil_from_hvac_component(hvac_equip.supplementalHeatingCoil)
      elsif hvac_equip.to_ZoneHVACTerminalUnitVariableRefrigerantFlow.is_initialized
        htg_coil = get_coil_from_hvac_component(hvac_equip.heatingCoil)
        clg_coil = get_coil_from_hvac_component(hvac_equip.coolingCoil)
      elsif hvac_equip.is_a? OpenStudio::Model::ZoneHVACBaseboardConvectiveWater
        htg_coil = get_coil_from_hvac_component(hvac_equip.heatingCoil)
      elsif hvac_equip.is_a? OpenStudio::Model::ZoneHVACPackagedTerminalAirConditioner
        htg_coil = get_coil_from_hvac_component(hvac_equip.heatingCoil)
        clg_coil = get_coil_from_hvac_component(hvac_equip.coolingCoil)
      end
      return clg_coil, htg_coil, supp_htg_coil
    end

    def self.get_coil_from_hvac_component(hvac_component)
      # Check for optional objects
      if (hvac_component.is_a? OpenStudio::Model::OptionalHVACComponent or
          hvac_component.is_a? OpenStudio::Model::OptionalCoilHeatingDXVariableRefrigerantFlow or
          hvac_component.is_a? OpenStudio::Model::OptionalCoilCoolingDXVariableRefrigerantFlow)
        return nil if not hvac_component.is_initialized
        hvac_component = hvac_component.get
      end
    
      # Cooling coils
      if hvac_component.to_CoilCoolingDXSingleSpeed.is_initialized
        return hvac_component.to_CoilCoolingDXSingleSpeed.get
      elsif hvac_component.to_CoilCoolingDXMultiSpeed.is_initialized
        return hvac_component.to_CoilCoolingDXMultiSpeed.get
      elsif hvac_component.to_CoilCoolingDXVariableRefrigerantFlow.is_initialized
        return hvac_component.to_CoilCoolingDXVariableRefrigerantFlow.get
      elsif hvac_component.to_CoilCoolingWaterToAirHeatPumpEquationFit.is_initialized
        return hvac_component.to_CoilCoolingWaterToAirHeatPumpEquationFit.get
      end
        
      # Heating coils  
      if hvac_component.to_CoilHeatingDXSingleSpeed.is_initialized
        return hvac_component.to_CoilHeatingDXSingleSpeed.get
      elsif hvac_component.to_CoilHeatingDXMultiSpeed.is_initialized
        return hvac_component.to_CoilHeatingDXMultiSpeed.get
      elsif hvac_component.to_CoilHeatingDXVariableRefrigerantFlow.is_initialized
        return hvac_component.to_CoilHeatingDXVariableRefrigerantFlow.get
      elsif hvac_component.to_CoilHeatingGas.is_initialized
        return hvac_component.to_CoilHeatingGas.get
      elsif hvac_component.to_CoilHeatingElectric.is_initialized
        return hvac_component.to_CoilHeatingElectric.get
      elsif hvac_component.to_CoilHeatingWaterBaseboard.is_initialized
        return hvac_component.to_CoilHeatingWaterBaseboard.get
      elsif hvac_component.to_CoilHeatingWaterToAirHeatPumpEquationFit.is_initialized
        return hvac_component.to_CoilHeatingWaterToAirHeatPumpEquationFit.get
      end
      return hvac_component
    end
    
    def self.get_unitary_system_air_loop(model, runner, thermal_zone)
      # Returns the unitary system, cooling coil, heating coil, and air loop if available
      model.getAirLoopHVACs.each do |air_loop|
        air_loop.thermalZones.each do |thermalZone|
          next unless thermal_zone.handle.to_s == thermalZone.handle.to_s
          air_loop.supplyComponents.each do |supply_component|
            next unless supply_component.to_AirLoopHVACUnitarySystem.is_initialized
            system = supply_component.to_AirLoopHVACUnitarySystem.get
            clg_coil = nil
            htg_coil = nil
            if system.coolingCoil.is_initialized
              clg_coil = system.coolingCoil.get
            end
            if system.heatingCoil.is_initialized
              htg_coil = system.heatingCoil.get
            end
            return system, clg_coil, htg_coil, air_loop
          end
        end
      end
      return nil, nil, nil, nil
    end
    
    def self.get_unitary_system_zone_hvac(model, runner, thermal_zone)
      # Returns the unitary system, cooling coil, and heating coil if available
      thermal_zone.equipment.each do |equipment|
        next unless equipment.to_AirLoopHVACUnitarySystem.is_initialized
        system = equipment.to_AirLoopHVACUnitarySystem.get
        clg_coil = nil
        htg_coil = nil
        if system.coolingCoil.is_initialized
          clg_coil = system.coolingCoil.get
        end
        if system.heatingCoil.is_initialized
          htg_coil = system.heatingCoil.get
        end
        return system, clg_coil, htg_coil
      end
      
      return nil, nil, nil, nil
    end
    
    def self.get_vrf(model, runner, thermal_zone)
      # Returns the VRF if available
      model.getAirConditionerVariableRefrigerantFlows.each do |vrf|
        vrf.terminals.each do |terminal|
          next unless thermal_zone.handle.to_s == terminal.thermalZone.get.handle.to_s
          return vrf
        end
      end
      return nil
    end
    
    def self.get_ptac(model, runner, thermal_zone)
      # Returns the PTAC if available
      model.getZoneHVACPackagedTerminalAirConditioners.each do |ptac|
        next unless thermal_zone.handle.to_s == ptac.thermalZone.get.handle.to_s
        return ptac
      end
      return nil
    end
    
    def self.get_baseboard_water(model, runner, thermal_zone)
      # Returns the water baseboard if available
      model.getZoneHVACBaseboardConvectiveWaters.each do |baseboard|
        next unless thermal_zone.handle.to_s == baseboard.thermalZone.get.handle.to_s
        return baseboard
      end
      return nil
    end
    
    def self.get_baseboard_electric(model, runner, thermal_zone)
      # Returns the electric baseboard if available
      model.getZoneHVACBaseboardConvectiveElectrics.each do |baseboard|
        next unless thermal_zone.handle.to_s == baseboard.thermalZone.get.handle.to_s
        return baseboard
      end
      return nil
    end
    
    def self.get_dehumidifier(model, runner, thermal_zone)
      # Returns the dehumidifier if available
      model.getZoneHVACDehumidifierDXs.each do |dehum|
        next unless thermal_zone.handle.to_s == dehum.thermalZone.get.handle.to_s
        return dehum
      end
      return nil
    end
    
    # Has Equipment methods
    
    def self.has_central_ac(model, runner, thermal_zone)
      system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
      if system.nil? or clg_coil.nil?
        return false
      end
      if not (clg_coil.to_CoilCoolingDXSingleSpeed.is_initialized or clg_coil.to_CoilCoolingDXMultiSpeed.is_initialized)
        return false
      end
      if not htg_coil.nil?
        if htg_coil.to_CoilHeatingDXSingleSpeed.is_initialized or htg_coil.to_CoilHeatingDXMultiSpeed.is_initialized
          return false # ASHP
        end
      end
      return true
    end
    
    def self.has_ashp(model, runner, thermal_zone)
      system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
      if system.nil? or clg_coil.nil? or htg_coil.nil?
        return false
      end
      if not (clg_coil.to_CoilCoolingDXSingleSpeed.is_initialized or clg_coil.to_CoilCoolingDXMultiSpeed.is_initialized)
        return false
      end
      if not (htg_coil.to_CoilHeatingDXSingleSpeed.is_initialized or htg_coil.to_CoilHeatingDXMultiSpeed.is_initialized)
        return false
      end
      return true
    end
    
    def self.has_gshp(model, runner, thermal_zone)
      system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
      if system.nil? or clg_coil.nil? or htg_coil.nil?
        return false
      end
      if not clg_coil.to_CoilCoolingWaterToAirHeatPumpEquationFit.is_initialized
        return false
      end
      if not htg_coil.to_CoilHeatingWaterToAirHeatPumpEquationFit.is_initialized
        return false
      end
      return true
    end
    
    def self.has_furnace(model, runner, thermal_zone)
      system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
      if system.nil? or htg_coil.nil?
        return false
      end
      if not (htg_coil.to_CoilHeatingGas.is_initialized or htg_coil.to_CoilHeatingElectric.is_initialized)
        return false
      end
      return true
    end
    
    def self.has_mshp(model, runner, thermal_zone)
      vrf = self.get_vrf(model, runner, thermal_zone)
      if vrf.nil?
        return false
      end
      return true
    end
    
    def self.has_ducted_mshp(model, runner, thermal_zone)
      if not self.has_mshp(model, runner, thermal_zone)
        return false
      end
      model.getBuildingUnits.each do |unit|
        next if not Geometry.get_thermal_zones_from_spaces(unit.spaces).include?(thermal_zone)
        is_ducted = unit.getFeatureAsBoolean(Constants.DuctedInfoMiniSplitHeatPump)
        if not is_ducted.is_initialized
          runner.registerError("Could not find value for '#{Constants.DuctedInfoMiniSplitHeatPump}' with datatype boolean.")
          return nil
        end
        return is_ducted.get
      end
      return false
    end
    
    def self.has_room_ac(model, runner, thermal_zone)
      ptac = self.get_ptac(model, runner, thermal_zone)
      if not ptac.nil?
        return true
      end
      return false
    end
    
    def self.has_boiler(model, runner, thermal_zone)
      baseboard = self.get_baseboard_water(model, runner, thermal_zone)
      if not baseboard.nil?
        return true
      end
      return false
    end
    
    def self.has_electric_baseboard(model, runner, thermal_zone)
      baseboard = self.get_baseboard_electric(model, runner, thermal_zone)
      if not baseboard.nil?
        return true
      end
      return false
    end
    
    def self.has_unit_heater(model, runner, thermal_zone)
      system, clg_coil, htg_coil = self.get_unitary_system_zone_hvac(model, runner, thermal_zone)
      if system.nil? or htg_coil.nil?
        return false
      end
      return true
    end
    
    def self.has_dehumidifier(model, runner, thermal_zone)
      dehum = self.get_dehumidifier(model, runner, thermal_zone)
      if dehum.nil?
        return false
      end
      return true
    end
    
    def self.has_ducted_equipment(model, runner, thermal_zone)
      if has_central_ac(model, runner, thermal_zone)
        return true
      elsif has_furnace(model, runner, thermal_zone)
        return true
      elsif has_ashp(model, runner, thermal_zone)
        return true
      elsif has_gshp(model, runner, thermal_zone)
        return true
      elsif has_ducted_mshp(model, runner, thermal_zone)
        return true
      end
      return false
    end
    
    # Remove Equipment methods
    
    def self.remove_central_ac(model, runner, thermal_zone)
      # Returns true if the object was removed
      return false if not self.has_central_ac(model, runner, thermal_zone)
      system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
      runner.registerInfo("Removed '#{clg_coil.name}' from '#{air_loop.name}'.")
      system.resetCoolingCoil
      clg_coil.remove
      system.supplyFan.get.remove
      return true
    end
    
    
    def self.remove_ashp(model, runner, thermal_zone)
      # Returns true if the object was removed
      return false if not self.has_ashp(model, runner, thermal_zone)
      system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
      runner.registerInfo("Removed '#{clg_coil.name}' and '#{htg_coil.name}' from '#{air_loop.name}'.")
      system.resetHeatingCoil
      system.resetCoolingCoil              
      htg_coil.remove
      clg_coil.remove
      return true
    end
    
    def self.remove_gshp(model, runner, thermal_zone)
      # Returns true if the object was removed
      return false if not self.has_gshp(model, runner, thermal_zone)
      system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
      runner.registerInfo("Removed '#{clg_coil.name}' and '#{htg_coil.name}' from '#{air_loop.name}'.")
      system.resetHeatingCoil
      system.resetCoolingCoil              
      htg_coil.remove
      clg_coil.remove
      return true
    end
    
    def self.remove_furnace(model, runner, thermal_zone)
      # Returns true if the object was removed
      return false if not self.has_furnace(model, runner, thermal_zone)
      system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
      runner.registerInfo("Removed '#{htg_coil.name}' from '#{air_loop.name}'.")
      system.resetHeatingCoil
      htg_coil.remove
      system.supplyFan.get.remove
      return true
    end
    
    def self.remove_mshp(model, runner, thermal_zone, unit)
      # Returns true if the object was removed
      return false if not self.has_mshp(model, runner, thermal_zone)
      vrf = self.get_vrf(model, runner, thermal_zone)
      runner.registerInfo("Removed '#{vrf.name}' from #{thermal_zone.name}.")
      vrf.terminals.each do |terminal|
        terminal.remove
      end
      vrf.remove

      obj_name = Constants.ObjectNameMiniSplitHeatPump(unit.name.to_s)
      
      model.getOutputVariables.each do |output_var|
        next unless output_var.name.to_s == "#{obj_name} vrf heat energy output var"
        output_var.remove
      end
      model.getOutputVariables.each do |output_var|
        next unless output_var.name.to_s == "#{obj_name} zone outdoor air drybulb temp output var"
        output_var.remove
      end

      model.getEnergyManagementSystemSensors.each do |sensor|
        next unless sensor.name.to_s == "#{obj_name} vrf energy sensor".gsub(" ","_").gsub("|","_")
        sensor.remove
      end
      model.getEnergyManagementSystemSensors.each do |sensor|
        next unless sensor.name.to_s == "#{obj_name} vrf fbsmt energy sensor".gsub(" ","_").gsub("|","_")
        sensor.remove
      end
      model.getEnergyManagementSystemSensors.each do |sensor|
        next unless sensor.name.to_s == "#{obj_name} tout sensor".gsub(" ","_").gsub("|","_")
        sensor.remove
      end
      model.getEnergyManagementSystemActuators.each do |actuator|
        next unless actuator.name.to_s == "#{obj_name} pan heater actuator".gsub(" ","_").gsub("|","_")
        actuator.remove
      end
      model.getEnergyManagementSystemPrograms.each do |program|
        next unless program.name.to_s == "#{obj_name} pan heater program".gsub(" ","_")
        program.remove
      end          
      model.getEnergyManagementSystemProgramCallingManagers.each do |program_calling_manager|
        next unless program_calling_manager.name.to_s == obj_name + " pan heater program calling manager"
        program_calling_manager.remove
      end
      
      thermal_zone.spaces.each do |space|
        space.electricEquipment.each do |equip|
          next unless equip.name.to_s == obj_name + " pan heater equip"
          equip.electricEquipmentDefinition.remove
        end
      end
      return true
    end
    
    def self.remove_room_ac(model, runner, thermal_zone)
      # Returns true if the object was removed
      return false if not self.has_room_ac(model, runner, thermal_zone)
      ptac = self.get_ptac(model, runner, thermal_zone)
      runner.registerInfo("Removed '#{ptac.name}' from #{thermal_zone.name}.")
      ptac.remove
      return true
    end
    
    def self.remove_boiler(model, runner, thermal_zone)
      # Returns true if the object was removed
      return false if not self.has_boiler(model, runner, thermal_zone)
      baseboard = self.get_baseboard_water(model, runner, thermal_zone)
      runner.registerInfo("Removed '#{baseboard.name}' from #{thermal_zone.name}.")
      baseboard.remove
      return true
    end
    
    def self.remove_electric_baseboard(model, runner, thermal_zone)
      # Returns true if the object was removed
      return false if not self.has_electric_baseboard(model, runner, thermal_zone)
      baseboard = self.get_baseboard_electric(model, runner, thermal_zone)
      runner.registerInfo("Removed '#{baseboard.name}' from #{thermal_zone.name}.")
      baseboard.remove
      return true
    end
    
    def self.remove_unit_heater(model, runner, thermal_zone)
      # Returns true if the object was removed
      return false if not self.has_unit_heater(model, runner, thermal_zone)
      system, clg_coil, htg_coil = self.get_unitary_system_zone_hvac(model, runner, thermal_zone)
      runner.registerInfo("Removed '#{system.name}' from '#{thermal_zone.name}'.")
      system.resetHeatingCoil
      htg_coil.remove
      if system.supplyFan.is_initialized
        system.supplyFan.get.remove
      end
      system.remove
      return true
    end
    
    def self.remove_boiler_and_gshp_loops(model, runner)
      # TODO: Add a BuildingUnit argument
      model.getPlantLoops.each do |plant_loop|
        remove = false
        plant_loop.supplyComponents.each do |supply_component|
          if supply_component.to_BoilerHotWater.is_initialized or supply_component.to_GroundHeatExchangerVertical.is_initialized or supply_component.to_GroundHeatExchangerHorizontalTrench.is_initialized
            remove = true
          end
        end
        if remove
          runner.registerInfo("Removed '#{plant_loop.name}' from model.")
          plant_loop.remove
        end
      end
    end 
    
    def self.remove_air_loop(model, runner, thermal_zone, clone_perf=false)
      # Returns the cloned perf or nil
      model.getAirLoopHVACs.each do |air_loop|
        air_loop.thermalZones.each do |thermalZone|
          next unless thermal_zone.handle.to_s == thermalZone.handle.to_s
          air_loop.supplyComponents.each do |supply_component|
            next unless supply_component.to_AirLoopHVACUnitarySystem.is_initialized
            air_loop_unitary = supply_component.to_AirLoopHVACUnitarySystem.get
            next if air_loop_unitary.heatingCoil.is_initialized or air_loop_unitary.coolingCoil.is_initialized
            runner.registerInfo("Removed '#{air_loop.name}' from #{thermal_zone.name}.")
            cloned_perf = nil
            if clone_perf and air_loop_unitary.designSpecificationMultispeedObject.is_initialized
              perf = air_loop_unitary.designSpecificationMultispeedObject.get
              cloned_perf = perf.clone.to_UnitarySystemPerformanceMultispeed.get
              cloned_perf.setName(perf.name.to_s)
            end
            air_loop.remove
            return cloned_perf
          end
        end
      end
      return nil
    end
    
    # Reset Equipment methods
    
    def self.reset_central_ac(model, runner, thermal_zone)
      # Returns the cloned coil or nil
      return nil if not self.has_central_ac(model, runner, thermal_zone)
      system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
      cloned_clg_coil = clg_coil.clone
      system.resetCoolingCoil
      clg_coil.remove
      system.supplyFan.get.remove
      cloned_clg_coil = self.get_coil_from_hvac_component(cloned_clg_coil)
      cloned_clg_coil.setName(clg_coil.name.to_s)
      return cloned_clg_coil
    end
    
    def self.reset_furnace(model, runner, thermal_zone)
      # Returns the cloned coil or nil
      return nil if not self.has_furnace(model, runner, thermal_zone)
      system, clg_coil, htg_coil, air_loop = self.get_unitary_system_air_loop(model, runner, thermal_zone)
      cloned_htg_coil = htg_coil.clone
      system.resetHeatingCoil
      htg_coil.remove
      system.supplyFan.get.remove
      if cloned_htg_coil.to_CoilHeatingGas.is_initialized
        cloned_htg_coil = cloned_htg_coil.to_CoilHeatingGas.get
      elsif cloned_htg_coil.to_CoilHeatingElectric.is_initialized
        cloned_htg_coil = cloned_htg_coil.to_CoilHeatingElectric.get
      end
      cloned_htg_coil.setName(htg_coil.name.to_s)
      return cloned_htg_coil
    end
    
    def self.remove_existing_hvac_equipment(model, runner, new_equip, thermal_zone, clone_perf, unit)
      counterpart_equip = nil
      perf = nil
      case new_equip
      when Constants.ObjectNameCentralAirConditioner
        removed_ashp = self.remove_ashp(model, runner, thermal_zone)
        removed_mshp = self.remove_mshp(model, runner, thermal_zone, unit)
        counterpart_equip = self.reset_furnace(model, runner, thermal_zone)
        removed_ac = self.remove_central_ac(model, runner, thermal_zone)
        removed_room_ac = self.remove_room_ac(model, runner, thermal_zone)
        removed_gshp = self.remove_gshp(model, runner, thermal_zone)
        if removed_mshp
          removed_elec_baseboard = self.remove_electric_baseboard(model, runner, thermal_zone)
        end
        if counterpart_equip or removed_ac or removed_ashp or removed_gshp
          self.remove_air_loop(model, runner, thermal_zone)
        end
        if removed_gshp
          self.remove_boiler_and_gshp_loops(model, runner)
        end
      when Constants.ObjectNameRoomAirConditioner
        removed_ashp = self.remove_ashp(model, runner, thermal_zone)
        removed_mshp = self.remove_mshp(model, runner, thermal_zone, unit)
        removed_room_ac = self.remove_room_ac(model, runner, thermal_zone)
        removed_ac = self.remove_central_ac(model, runner, thermal_zone)
        removed_gshp = self.remove_gshp(model, runner, thermal_zone)
        if removed_mshp
          removed_elec_baseboard = self.remove_electric_baseboard(model, runner, thermal_zone)
        end        
        if removed_ac or removed_ashp or removed_gshp
          self.remove_air_loop(model, runner, thermal_zone)
        end
        if removed_gshp
          self.remove_boiler_and_gshp_loops(model, runner)
        end        
      when Constants.ObjectNameFurnace
        removed_ashp = self.remove_ashp(model, runner, thermal_zone)
        removed_mshp = self.remove_mshp(model, runner, thermal_zone, unit)
        counterpart_equip = self.reset_central_ac(model, runner, thermal_zone)
        removed_furnace = self.remove_furnace(model, runner, thermal_zone)
        removed_boiler = self.remove_boiler(model, runner, thermal_zone)
        removed_heater = self.remove_unit_heater(model, runner, thermal_zone)
        removed_elec_baseboard = self.remove_electric_baseboard(model, runner, thermal_zone)
        removed_gshp = self.remove_gshp(model, runner, thermal_zone)
        if counterpart_equip or removed_furnace or removed_ashp or removed_gshp
          if removed_ashp or removed_gshp
            clone_perf = false
          end
          perf = self.remove_air_loop(model, runner, thermal_zone, clone_perf)
        end
      when Constants.ObjectNameBoiler
        removed_boiler = self.remove_boiler(model, runner, thermal_zone)
        removed_heater = self.remove_unit_heater(model, runner, thermal_zone)
        removed_furnace = self.remove_furnace(model, runner, thermal_zone)
        removed_elec_baseboard = self.remove_electric_baseboard(model, runner, thermal_zone)
        removed_ashp = self.remove_ashp(model, runner, thermal_zone)
        removed_mshp = self.remove_mshp(model, runner, thermal_zone, unit)
        removed_gshp = self.remove_gshp(model, runner, thermal_zone)
        if removed_furnace or removed_ashp or removed_mshp or removed_gshp
          self.remove_air_loop(model, runner, thermal_zone)
        end
      when Constants.ObjectNameElectricBaseboard
        removed_elec_baseboard = self.remove_electric_baseboard(model, runner, thermal_zone)
        removed_furnace = self.remove_furnace(model, runner, thermal_zone)
        removed_boiler = self.remove_boiler(model, runner, thermal_zone)
        removed_heater = self.remove_unit_heater(model, runner, thermal_zone)
        removed_ashp = self.remove_ashp(model, runner, thermal_zone)
        removed_mshp = self.remove_mshp(model, runner, thermal_zone, unit)
        removed_gshp = self.remove_gshp(model, runner, thermal_zone)
        if removed_furnace or removed_ashp or removed_gshp
          self.remove_air_loop(model, runner, thermal_zone)
        end
      when Constants.ObjectNameAirSourceHeatPump
        removed_ashp = self.remove_ashp(model, runner, thermal_zone)
        removed_mshp = self.remove_mshp(model, runner, thermal_zone, unit)
        removed_ac = self.remove_central_ac(model, runner, thermal_zone)
        removed_room_ac = self.remove_room_ac(model, runner, thermal_zone)
        removed_furnace = self.remove_furnace(model, runner, thermal_zone)
        removed_boiler = self.remove_boiler(model, runner, thermal_zone)
        removed_heater = self.remove_unit_heater(model, runner, thermal_zone)
        removed_elec_baseboard = self.remove_electric_baseboard(model, runner, thermal_zone)
        removed_gshp = self.remove_gshp(model, runner, thermal_zone)
        if removed_ashp or removed_ac or removed_furnace or removed_gshp
          self.remove_air_loop(model, runner, thermal_zone)
        end
      when Constants.ObjectNameMiniSplitHeatPump
        removed_mshp = self.remove_mshp(model, runner, thermal_zone, unit)
        removed_ashp = self.remove_ashp(model, runner, thermal_zone)
        removed_ac = self.remove_central_ac(model, runner, thermal_zone)
        removed_room_ac = self.remove_room_ac(model, runner, thermal_zone)
        removed_furnace = self.remove_furnace(model, runner, thermal_zone)
        removed_boiler = self.remove_boiler(model, runner, thermal_zone)
        removed_heater = self.remove_unit_heater(model, runner, thermal_zone)
        removed_elec_baseboard = self.remove_electric_baseboard(model, runner, thermal_zone)
        removed_gshp = self.remove_gshp(model, runner, thermal_zone)
        if removed_ac or removed_furnace or removed_ashp or removed_gshp
          self.remove_air_loop(model, runner, thermal_zone)
        end
      when Constants.ObjectNameGroundSourceHeatPumpVerticalBore
        removed_ashp = self.remove_ashp(model, runner, thermal_zone)
        removed_mshp = self.remove_mshp(model, runner, thermal_zone, unit)
        removed_ac = self.remove_central_ac(model, runner, thermal_zone)
        removed_room_ac = self.remove_room_ac(model, runner, thermal_zone)
        removed_furnace = self.remove_furnace(model, runner, thermal_zone)
        removed_boiler = self.remove_boiler(model, runner, thermal_zone)
        removed_heater = self.remove_unit_heater(model, runner, thermal_zone)
        removed_elec_baseboard = self.remove_electric_baseboard(model, runner, thermal_zone)
        removed_gshp = self.remove_gshp(model, runner, thermal_zone)
        if removed_ashp or removed_ac or removed_furnace or removed_gshp
          self.remove_air_loop(model, runner, thermal_zone)
        end
      when Constants.ObjectNameUnitHeater
        removed_elec_baseboard = self.remove_electric_baseboard(model, runner, thermal_zone)
        removed_furnace = self.remove_furnace(model, runner, thermal_zone)
        removed_boiler = self.remove_boiler(model, runner, thermal_zone)
        removed_heater = self.remove_unit_heater(model, runner, thermal_zone)
        removed_ashp = self.remove_ashp(model, runner, thermal_zone)
        removed_mshp = self.remove_mshp(model, runner, thermal_zone, unit)
        removed_gshp = self.remove_gshp(model, runner, thermal_zone)
        if removed_furnace or removed_ashp or removed_gshp
          self.remove_air_loop(model, runner, thermal_zone)
        end
      end
      return counterpart_equip, perf
    end   
    
    def self.prioritize_zone_hvac(model, runner, zone)
      zone_hvac_priority_list = [
                                 "ZoneHVACEnergyRecoveryVentilator", 
                                 "ZoneHVACTerminalUnitVariableRefrigerantFlow", 
                                 "AirLoopHVACUnitarySystem",
                                 "ZoneHVACBaseboardConvectiveElectric", 
                                 "ZoneHVACBaseboardConvectiveWater", 
                                 "AirTerminalSingleDuctUncontrolled", 
                                 "ZoneHVACDehumidifierDX", 
                                 "ZoneHVACPackagedTerminalAirConditioner"
                                ]    
      zone_hvac_list = []
      zone_hvac_priority_list.each do |zone_hvac_type|
        zone.equipment.each do |object|
          next if not object.respond_to?("to_#{zone_hvac_type}")
          next if not object.public_send("to_#{zone_hvac_type}").is_initialized
          new_object = object.public_send("to_#{zone_hvac_type}").get
          zone_hvac_list << new_object
        end
      end
      zone_hvac_list.reverse.each do |object|
        zone.setCoolingPriority(object, 1)
        zone.setHeatingPriority(object, 1)
      end
    end
    
    # Calculates heating/cooling seasons from BAHSP definition
    def self.calc_heating_and_cooling_seasons(model, weather, runner=nil)
      monthly_temps = weather.data.MonthlyAvgDrybulbs
      heat_design_db = weather.design.HeatingDrybulb
      
      # create basis lists with zero for every month
      cooling_season_temp_basis = Array.new(monthly_temps.length, 0.0)
      heating_season_temp_basis = Array.new(monthly_temps.length, 0.0)

      monthly_temps.each_with_index do |temp, i|
        if temp < 66.0
          heating_season_temp_basis[i] = 1.0
        elsif temp >= 66.0
          cooling_season_temp_basis[i] = 1.0
        end

        if (i == 0 or i == 11) and heat_design_db < 59.0
          heating_season_temp_basis[i] = 1.0
        elsif i == 6 or i == 7
          cooling_season_temp_basis[i] = 1.0
        end
      end

      cooling_season = Array.new(monthly_temps.length, 0.0)
      heating_season = Array.new(monthly_temps.length, 0.0)

      monthly_temps.each_with_index do |temp, i|
        # Heating overlaps with cooling at beginning of summer
        if i == 0 # January
          prevmonth = 11 # December
        else
          prevmonth = i - 1
        end

        if (heating_season_temp_basis[i] == 1.0 or (cooling_season_temp_basis[prevmonth] == 0.0 and cooling_season_temp_basis[i] == 1.0))
          heating_season[i] = 1.0
        else
          heating_season[i] = 0.0
        end

        if (cooling_season_temp_basis[i] == 1.0 or (heating_season_temp_basis[prevmonth] == 0.0 and heating_season_temp_basis[i] == 1.0))
          cooling_season[i] = 1.0
        else
          cooling_season[i] = 0.0
        end
      end

      # Find the first month of cooling and add one month
      (1...12).to_a.each do |i|
        if cooling_season[i] == 1.0
          cooling_season[i - 1] = 1.0
          break
        end
      end
      
      return heating_season, cooling_season
    end
    
    def self.calc_mshp_cfms_ton_cooling(cap_min_per, cap_max_per, cfm_ton_min, cfm_ton_max, num_speeds, dB_rated, wB_rated, shr)
    
      capacity_ratios_cooling = [0.0] * num_speeds
      cfms_cooling = [0.0] * num_speeds
      shrs_rated = [0.0] * num_speeds
      
      cap_nom_per = cap_max_per
      cfm_ton_nom = ((cfm_ton_max - cfm_ton_min)/(cap_max_per - cap_min_per)) * (cap_nom_per - cap_min_per) + cfm_ton_min
      
      ao = Psychrometrics.CoilAoFactor(dB_rated, wB_rated, Constants.Patm, UnitConversions.convert(1,"ton","kBtu/hr"), cfm_ton_nom, shr)
      
      (0...num_speeds).each do |i|
          capacity_ratios_cooling[i] = cap_min_per + i*(cap_max_per - cap_min_per)/(num_speeds-1)
          cfms_cooling[i] = cfm_ton_min + i*(cfm_ton_max - cfm_ton_min)/(num_speeds-1)
          # Calculate the SHR for each speed. Use minimum value of 0.98 to prevent E+ bypass factor calculation errors
          shrs_rated[i] = [Psychrometrics.CalculateSHR(dB_rated, wB_rated, Constants.Patm, UnitConversions.convert(capacity_ratios_cooling[i],"ton","kBtu/hr"), cfms_cooling[i], ao), 0.98].min
      end
    
      return cfms_cooling, capacity_ratios_cooling, shrs_rated
    end
    
    def self.calc_mshp_cooling_eirs(runner, coolingSEER, supplyFanPower, c_d, num_speeds, capacity_ratios_cooling, cfms_cooling, cOOL_EIR_FT_SPEC, cOOL_CAP_FT_SPEC)
          
      cops_Norm = [1.901, 1.859, 1.746, 1.609, 1.474, 1.353, 1.247, 1.156, 1.079, 1.0]
      fanPows_Norm = [0.604, 0.634, 0.670, 0.711, 0.754, 0.800, 0.848, 0.898, 0.948, 1.0]
      
      cooling_eirs = [0.0] * num_speeds
      fanPowsRated = [0.0] * num_speeds
      eers_Rated = [0.0] * num_speeds
      
      cop_maxSpeed = 3.5  # 3.5 is an initial guess, final value solved for below
      
      (0...num_speeds).each do |i|
          fanPowsRated[i] = supplyFanPower * fanPows_Norm[i] 
          eers_Rated[i] = UnitConversions.convert(cop_maxSpeed,"W","Btu/hr") * cops_Norm[i]   
      end 
          
      cop_maxSpeed_1 = cop_maxSpeed
      cop_maxSpeed_2 = cop_maxSpeed                
      error = coolingSEER - calc_mshp_SEER_VariableSpeed(eers_Rated, c_d, capacity_ratios_cooling, cfms_cooling, fanPowsRated, true, cOOL_EIR_FT_SPEC, cOOL_CAP_FT_SPEC)
      error1 = error
      error2 = error
      
      itmax = 50  # maximum iterations
      cvg = false
      final_n = nil
      
      (1...itmax+1).each do |n|
          final_n = n
          (0...num_speeds).each do |i|
              eers_Rated[i] = UnitConversions.convert(cop_maxSpeed,"W","Btu/hr") * cops_Norm[i]
          end
          
          error = coolingSEER - calc_mshp_SEER_VariableSpeed(eers_Rated, c_d, capacity_ratios_cooling, cfms_cooling, fanPowsRated, true, cOOL_EIR_FT_SPEC, cOOL_CAP_FT_SPEC)
          
          cop_maxSpeed,cvg,cop_maxSpeed_1,error1,cop_maxSpeed_2,error2 = MathTools.Iterate(cop_maxSpeed,error,cop_maxSpeed_1,error1,cop_maxSpeed_2,error2,n,cvg)
      
          if cvg 
              break
          end
      end

      if not cvg or final_n > itmax
          cop_maxSpeed = UnitConversions.convert(0.547*coolingSEER - 0.104,"Btu/hr","W")  # Correlation developed from JonW's MatLab scripts. Only used is an EER cannot be found.   
          runner.registerWarning('Mini-split heat pump COP iteration failed to converge. Setting to default value.')
      end
          
      (0...num_speeds).each do |i|
          cooling_eirs[i] = calc_EIR_from_EER(UnitConversions.convert(cop_maxSpeed,"W","Btu/hr") * cops_Norm[i], fanPowsRated[i])
      end

      return cooling_eirs

    end
    
    def self.calc_mshp_SEER_VariableSpeed(eer_A, c_d, capacityRatio, cfm_Tons, supplyFanPower_Rated, isHeatPump, cOOL_EIR_FT_SPEC, cOOL_CAP_FT_SPEC)
      
      n_max = (eer_A.length-1.0)-3.0 # Don't use max speed
      n_min = 0.0
      n_int = (n_min + (n_max-n_min)/3.0).ceil.to_i

      wBin = UnitConversions.convert(67.0,"F","C")
      tout_B = UnitConversions.convert(82.0,"F","C")
      tout_E = UnitConversions.convert(87.0,"F","C")
      tout_F = UnitConversions.convert(67.0,"F","C")

      eir_A2 = calc_EIR_from_EER(eer_A[n_max], supplyFanPower_Rated[n_max])    
      eir_B2 = eir_A2 * MathTools.biquadratic(wBin, tout_B, cOOL_EIR_FT_SPEC[n_max]) 
      
      eir_Av = calc_EIR_from_EER(eer_A[n_int], supplyFanPower_Rated[n_int])    
      eir_Ev = eir_Av * MathTools.biquadratic(wBin, tout_E, cOOL_EIR_FT_SPEC[n_int])
      
      eir_A1 = calc_EIR_from_EER(eer_A[n_min], supplyFanPower_Rated[n_min])
      eir_B1 = eir_A1 * MathTools.biquadratic(wBin, tout_B, cOOL_EIR_FT_SPEC[n_min]) 
      eir_F1 = eir_A1 * MathTools.biquadratic(wBin, tout_F, cOOL_EIR_FT_SPEC[n_min])
      
      q_A2 = capacityRatio[n_max]
      q_B2 = q_A2 * MathTools.biquadratic(wBin, tout_B, cOOL_CAP_FT_SPEC[n_max])    
      q_Ev = capacityRatio[n_int] * MathTools.biquadratic(wBin, tout_E, cOOL_CAP_FT_SPEC[n_int])            
      q_B1 = capacityRatio[n_min] * MathTools.biquadratic(wBin, tout_B, cOOL_CAP_FT_SPEC[n_min])
      q_F1 = capacityRatio[n_min] * MathTools.biquadratic(wBin, tout_F, cOOL_CAP_FT_SPEC[n_min])
              
      q_A2_net = q_A2 - supplyFanPower_Rated[n_max] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_max] / UnitConversions.convert(1,"ton","Btu/hr")
      q_B2_net = q_B2 - supplyFanPower_Rated[n_max] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_max] / UnitConversions.convert(1,"ton","Btu/hr")       
      q_Ev_net = q_Ev - supplyFanPower_Rated[n_int] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_int] / UnitConversions.convert(1,"ton","Btu/hr")
      q_B1_net = q_B1 - supplyFanPower_Rated[n_min] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_min] / UnitConversions.convert(1,"ton","Btu/hr")
      q_F1_net = q_F1 - supplyFanPower_Rated[n_min] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_min] / UnitConversions.convert(1,"ton","Btu/hr")
      
      p_A2 = UnitConversions.convert(q_A2 * eir_A2,"Btu","Wh") + supplyFanPower_Rated[n_max] * cfm_Tons[n_max] / UnitConversions.convert(1,"ton","Btu/hr")
      p_B2 = UnitConversions.convert(q_B2 * eir_B2,"Btu","Wh") + supplyFanPower_Rated[n_max] * cfm_Tons[n_max] / UnitConversions.convert(1,"ton","Btu/hr")
      p_Ev = UnitConversions.convert(q_Ev * eir_Ev,"Btu","Wh") + supplyFanPower_Rated[n_int] * cfm_Tons[n_int] / UnitConversions.convert(1,"ton","Btu/hr")
      p_B1 = UnitConversions.convert(q_B1 * eir_B1,"Btu","Wh") + supplyFanPower_Rated[n_min] * cfm_Tons[n_min] / UnitConversions.convert(1,"ton","Btu/hr")
      p_F1 = UnitConversions.convert(q_F1 * eir_F1,"Btu","Wh") + supplyFanPower_Rated[n_min] * cfm_Tons[n_min] / UnitConversions.convert(1,"ton","Btu/hr")
      
      q_k1_87 = q_F1_net + (q_B1_net - q_F1_net) / (82.0 - 67.0) * (87 - 67.0)
      q_k2_87 = q_B2_net + (q_A2_net - q_B2_net) / (95.0 - 82.0) * (87.0 - 82.0)
      n_Q = (q_Ev_net - q_k1_87) / (q_k2_87 - q_k1_87)
      m_Q = (q_B1_net - q_F1_net) / (82.0 - 67.0) * (1.0 - n_Q) + (q_A2_net - q_B2_net) / (95.0 - 82.0) * n_Q    
      p_k1_87 = p_F1 + (p_B1 - p_F1) / (82.0 - 67.0) * (87.0 - 67.0)
      p_k2_87 = p_B2 + (p_A2 - p_B2) / (95.0 - 82.0) * (87.0 - 82.0)
      n_E = (p_Ev - p_k1_87) / (p_k2_87 - p_k1_87)
      m_E = (p_B1 - p_F1) / (82.0 - 67.0) * (1.0 - n_E) + (p_A2 - p_B2) / (95.0 - 82.0) * n_E
      
      c_T_1_1 = q_A2_net / (1.1 * (95.0 - 65.0))
      c_T_1_2 = q_F1_net
      c_T_1_3 = (q_B1_net - q_F1_net) / (82.0 - 67.0)
      t_1 = (c_T_1_2 - 67.0*c_T_1_3 + 65.0*c_T_1_1) / (c_T_1_1 - c_T_1_3)
      q_T_1 = q_F1_net + (q_B1_net - q_F1_net) / (82.0 - 67.0) * (t_1 - 67.0)
      p_T_1 = p_F1 + (p_B1 - p_F1) / (82.0 - 67.0) * (t_1 - 67.0)
      eer_T_1 = q_T_1 / p_T_1 
       
      t_v = (q_Ev_net - 87.0*m_Q + 65.0*c_T_1_1) / (c_T_1_1 - m_Q)
      q_T_v = q_Ev_net + m_Q * (t_v - 87.0)
      p_T_v = p_Ev + m_E * (t_v - 87.0)
      eer_T_v = q_T_v / p_T_v
      
      c_T_2_1 = c_T_1_1
      c_T_2_2 = q_B2_net
      c_T_2_3 = (q_A2_net - q_B2_net) / (95.0 - 82.0)
      t_2 = (c_T_2_2 - 82.0*c_T_2_3 + 65.0*c_T_2_1) / (c_T_2_1 - c_T_2_3)
      q_T_2 = q_B2_net + (q_A2_net - q_B2_net) / (95.0 - 82.0) * (t_2 - 82.0)
      p_T_2 = p_B2 + (p_A2 - p_B2) / (95.0 - 82.0) * (t_2 - 82.0)
      eer_T_2 = q_T_2 / p_T_2 
      
      d = (t_2**2 - t_1**2) / (t_v**2 - t_1**2)
      b = (eer_T_1 - eer_T_2 - d * (eer_T_1 - eer_T_v)) / (t_1 - t_2 - d * (t_1 - t_v))
      c = (eer_T_1 - eer_T_2 - b * (t_1 - t_2)) / (t_1**2 - t_2**2)
      a = eer_T_2 - b * t_2 - c * t_2**2
      
      e_tot = 0
      q_tot = 0    
      t_bins = [67.0,72.0,77.0,82.0,87.0,92.0,97.0,102.0]
      frac_hours = [0.214,0.231,0.216,0.161,0.104,0.052,0.018,0.004]    
      
      (0...8).each do |_i|
          bL = ((t_bins[_i] - 65.0) / (95.0 - 65.0)) * (q_A2_net / 1.1)
          q_k1 = q_F1_net + (q_B1_net - q_F1_net) / (82.0 - 67.0) * (t_bins[_i] - 67.0)
          p_k1 = p_F1 + (p_B1 - p_F1) / (82.0 - 67.0) * (t_bins[_i] - 67)                                
          q_k2 = q_B2_net + (q_A2_net - q_B2_net) / (95.0 - 82.0) * (t_bins[_i] - 82.0)
          p_k2 = p_B2 + (p_A2 - p_B2) / (95.0 - 82.0) * (t_bins[_i] - 82.0)
                  
          if bL <= q_k1
              x_k1 = bL / q_k1        
              q_Tj_N = x_k1 * q_k1 * frac_hours[_i]
              e_Tj_N = x_k1 * p_k1 * frac_hours[_i] / (1 - c_d * (1 - x_k1))
          elsif q_k1 < bL and bL <= q_k2
              q_Tj_N = bL * frac_hours[_i]
              eer_T_j = a + b * t_bins[_i] + c * t_bins[_i]**2
              e_Tj_N = q_Tj_N / eer_T_j
          else
              q_Tj_N = frac_hours[_i] * q_k2
              e_Tj_N = frac_hours[_i] * p_k2
          end
           
          q_tot = q_tot + q_Tj_N
          e_tot = e_tot + e_Tj_N   
      end

      seer = q_tot / e_tot
      return seer
    end
    
    def self.calc_mshp_cfms_ton_heating(cap_min_per, cap_max_per, cfm_ton_min, cfm_ton_max, num_speeds)
    
      capacity_ratios_heating = [0.0] * num_speeds
      cfms_heating = [0.0] * num_speeds
    
      (0...num_speeds).each do |i|
          capacity_ratios_heating[i] = cap_min_per + i*(cap_max_per - cap_min_per)/(num_speeds-1)
          cfms_heating[i] = cfm_ton_min + i*(cfm_ton_max - cfm_ton_min)/(num_speeds-1)
      end
    
      return cfms_heating, capacity_ratios_heating
    end
    
    def self.calc_mshp_heating_eirs(runner, heatingHSPF, supplyFanPower, mshp_capacity_retention_fraction, mshp_capacity_retention_temperature, min_hp_temp, c_d, cfms_cooling, num_speeds, capacity_ratios_heating, cfms_heating, hEAT_EIR_FT_SPEC, hEAT_CAP_FT_SPEC)
          
      #COPs_Norm = [1.636, 1.757, 1.388, 1.240, 1.162, 1.119, 1.084, 1.062, 1.044, 1] #Report Avg
      #COPs_Norm = [1.792, 1.502, 1.308, 1.207, 1.145, 1.105, 1.077, 1.056, 1.041, 1] #BEopt Default
      
      cops_Norm = [1.792, 1.502, 1.308, 1.207, 1.145, 1.105, 1.077, 1.056, 1.041, 1] #BEopt Default    
      fanPows_Norm = [0.577, 0.625, 0.673, 0.720, 0.768, 0.814, 0.861, 0.907, 0.954, 1]

      heating_eirs = [0.0] * num_speeds
      fanPowsRated = [0.0] * num_speeds
      cops_Rated = [0.0] * num_speeds
      
      cop_maxSpeed = 3.25  # 3.35 is an initial guess, final value solved for below
      
      (0...num_speeds).each do |i|
          fanPowsRated[i] = supplyFanPower * fanPows_Norm[i] 
          cops_Rated[i] = cop_maxSpeed * cops_Norm[i]
      end
          
      cop_maxSpeed_1 = cop_maxSpeed
      cop_maxSpeed_2 = cop_maxSpeed                
      error = heatingHSPF - calc_mshp_HSPF_VariableSpeed(cops_Rated, c_d, capacity_ratios_heating, cfms_heating, fanPowsRated, min_hp_temp, mshp_capacity_retention_fraction, mshp_capacity_retention_temperature, hEAT_EIR_FT_SPEC, hEAT_CAP_FT_SPEC)
      
      error1 = error
      error2 = error
      
      itmax = 50  # maximum iterations
      cvg = false
      final_n = nil
      
      (1...itmax+1).each do |n|
          final_n = n
          (0...num_speeds).each do |i|          
              cops_Rated[i] = cop_maxSpeed * cops_Norm[i]
          end
          
          error = heatingHSPF - calc_mshp_HSPF_VariableSpeed(cops_Rated, c_d, capacity_ratios_heating, cfms_cooling, fanPowsRated, min_hp_temp, mshp_capacity_retention_fraction, mshp_capacity_retention_temperature, hEAT_EIR_FT_SPEC, hEAT_CAP_FT_SPEC)
          
          cop_maxSpeed,cvg,cop_maxSpeed_1,error1,cop_maxSpeed_2,error2 = MathTools.Iterate(cop_maxSpeed,error,cop_maxSpeed_1,error1,cop_maxSpeed_2,error2,n,cvg)
      
          if cvg
              break
          end
      end
      
      if not cvg or final_n > itmax
          cop_maxSpeed = UnitConversions.convert(0.4174*heatingHSPF - 1.1134,"Btu/hr","W")  # Correlation developed from JonW's MatLab scripts. Only used if a COP cannot be found.   
          runner.registerWarning('Mini-split heat pump COP iteration failed to converge. Setting to default value.')
      end

      (0...num_speeds).each do |i|
          heating_eirs[i] = calc_EIR_from_COP(cop_maxSpeed * cops_Norm[i], fanPowsRated[i])
      end

      return heating_eirs
      
    end  
    
    def self.calc_mshp_HSPF_VariableSpeed(cop_47, c_d, capacityRatio, cfm_Tons, supplyFanPower_Rated, min_temp, mshp_capacity_retention_fraction, mshp_capacity_retention_temperature, hEAT_EIR_FT_SPEC, hEAT_CAP_FT_SPEC)
      
      n_max = (cop_47.length-1.0)#-3 # Don't use max speed
      n_min = 0
      n_int = (n_min + (n_max-n_min)/3.0).ceil.to_i

      tin = UnitConversions.convert(70.0,"F","C")
      tout_3 = UnitConversions.convert(17.0,"F","C")
      tout_2 = UnitConversions.convert(35.0,"F","C")
      tout_0 = UnitConversions.convert(62.0,"F","C")
      
      eir_H1_2 = calc_EIR_from_COP(cop_47[n_max], supplyFanPower_Rated[n_max])    
      eir_H3_2 = eir_H1_2 * MathTools.biquadratic(tin, tout_3, hEAT_EIR_FT_SPEC[n_max])

      eir_adjv = calc_EIR_from_COP(cop_47[n_int], supplyFanPower_Rated[n_int])    
      eir_H2_v = eir_adjv * MathTools.biquadratic(tin, tout_2, hEAT_EIR_FT_SPEC[n_int])
          
      eir_H1_1 = calc_EIR_from_COP(cop_47[n_min], supplyFanPower_Rated[n_min])
      eir_H0_1 = eir_H1_1 * MathTools.biquadratic(tin, tout_0, hEAT_EIR_FT_SPEC[n_min])
          
      q_H1_2 = capacityRatio[n_max]
      q_H3_2 = q_H1_2 * MathTools.biquadratic(tin, tout_3, hEAT_CAP_FT_SPEC[n_max])    
          
      q_H2_v = capacityRatio[n_int] * MathTools.biquadratic(tin, tout_2, hEAT_CAP_FT_SPEC[n_int])
      
      q_H1_1 = capacityRatio[n_min]
      q_H0_1 = q_H1_1 * MathTools.biquadratic(tin, tout_0, hEAT_CAP_FT_SPEC[n_min])
                                    
      q_H1_2_net = q_H1_2 + supplyFanPower_Rated[n_max] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_max] / UnitConversions.convert(1,"ton","Btu/hr")
      q_H3_2_net = q_H3_2 + supplyFanPower_Rated[n_max] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_max] / UnitConversions.convert(1,"ton","Btu/hr")
      q_H2_v_net = q_H2_v + supplyFanPower_Rated[n_int] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_int] / UnitConversions.convert(1,"ton","Btu/hr")
      q_H1_1_net = q_H1_1 + supplyFanPower_Rated[n_min] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_min] / UnitConversions.convert(1,"ton","Btu/hr")
      q_H0_1_net = q_H0_1 + supplyFanPower_Rated[n_min] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_min] / UnitConversions.convert(1,"ton","Btu/hr")
                                   
      p_H1_2 = q_H1_2 * eir_H1_2 + supplyFanPower_Rated[n_max] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_max] / UnitConversions.convert(1,"ton","Btu/hr")
      p_H3_2 = q_H3_2 * eir_H3_2 + supplyFanPower_Rated[n_max] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_max] / UnitConversions.convert(1,"ton","Btu/hr")
      p_H2_v = q_H2_v * eir_H2_v + supplyFanPower_Rated[n_int] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_int] / UnitConversions.convert(1,"ton","Btu/hr")
      p_H1_1 = q_H1_1 * eir_H1_1 + supplyFanPower_Rated[n_min] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_min] / UnitConversions.convert(1,"ton","Btu/hr")
      p_H0_1 = q_H0_1 * eir_H0_1 + supplyFanPower_Rated[n_min] * UnitConversions.convert(1,"W","Btu/hr") * cfm_Tons[n_min] / UnitConversions.convert(1,"ton","Btu/hr")
          
      q_H35_2 = 0.9 * (q_H3_2_net + 0.6 * (q_H1_2_net - q_H3_2_net))
      p_H35_2 = 0.985 * (p_H3_2 + 0.6 * (p_H1_2 - p_H3_2))
      q_H35_1 = q_H1_1_net + (q_H0_1_net - q_H1_1_net) / (62.0 - 47.0) * (35.0 - 47.0)
      p_H35_1 = p_H1_1 + (p_H0_1 - p_H1_1) / (62.0 - 47.0) * (35.0 - 47.0)
      n_Q = (q_H2_v_net - q_H35_1) / (q_H35_2 - q_H35_1)
      m_Q = (q_H0_1_net - q_H1_1_net) / (62.0 - 47.0) * (1 - n_Q) + n_Q * (q_H35_2 - q_H3_2_net) / (35.0 - 17.0)
      n_E = (p_H2_v - p_H35_1) / (p_H35_2 - p_H35_1)
      m_E = (p_H0_1 - p_H1_1) / (62.0 - 47.0) * (1.0 - n_E) + n_E * (p_H35_2 - p_H3_2) / (35.0 - 17.0)    
      
      t_OD = 5.0
      dHR = q_H1_2_net * (65.0 - t_OD) / 60.0
      
      c_T_3_1 = q_H1_1_net
      c_T_3_2 = (q_H0_1_net - q_H1_1_net) / (62.0 - 47.0)
      c_T_3_3 = 0.77 * dHR / (65.0 - t_OD)
      t_3 = (47.0 * c_T_3_2 + 65.0 * c_T_3_3 - c_T_3_1) / (c_T_3_2 + c_T_3_3)
      q_HT3_1 = q_H1_1_net + (q_H0_1_net - q_H1_1_net) / (62.0 - 47.0) * (t_3 - 47.0)
      p_HT3_1 = p_H1_1 + (p_H0_1 - p_H1_1) / (62.0 - 47.0) * (t_3 - 47.0)
      cop_T3_1 = q_HT3_1 / p_HT3_1
      
      c_T_v_1 = q_H2_v_net
      c_T_v_3 = c_T_3_3
      t_v = (35.0 * m_Q + 65.0 * c_T_v_3 - c_T_v_1) / (m_Q + c_T_v_3)
      q_HTv_v = q_H2_v_net + m_Q * (t_v - 35.0)
      p_HTv_v = p_H2_v + m_E * (t_v - 35.0)
      cop_Tv_v = q_HTv_v / p_HTv_v
      
      c_T_4_1 = q_H3_2_net
      c_T_4_2 = (q_H35_2 - q_H3_2_net) / (35.0 - 17.0)
      c_T_4_3 = c_T_v_3
      t_4 = (17.0 * c_T_4_2 + 65.0 * c_T_4_3 - c_T_4_1) / (c_T_4_2 + c_T_4_3)
      q_HT4_2 = q_H3_2_net + (q_H35_2 - q_H3_2_net) / (35.0 - 17.0) * (t_4 - 17.0)
      p_HT4_2 = p_H3_2 + (p_H35_2 - p_H3_2) / (35.0 - 17.0) * (t_4 - 17.0)
      cop_T4_2 = q_HT4_2 / p_HT4_2
      
      d = (t_3**2 - t_4**2) / (t_v**2 - t_4**2)
      b = (cop_T4_2 - cop_T3_1 - d * (cop_T4_2 - cop_Tv_v)) / (t_4 - t_3 - d * (t_4 - t_v))
      c = (cop_T4_2 - cop_T3_1 - b * (t_4 - t_3)) / (t_4**2 - t_3**2)
      a = cop_T4_2 - b * t_4 - c * t_4**2
      
      t_bins = [62.0,57.0,52.0,47.0,42.0,37.0,32.0,27.0,22.0,17.0,12.0,7.0,2.0,-3.0,-8.0]
      frac_hours = [0.132,0.111,0.103,0.093,0.100,0.109,0.126,0.087,0.055,0.036,0.026,0.013,0.006,0.002,0.001]
          
      # T_off = min_temp
      t_off = 10.0
      t_on = t_off + 4.0
      etot = 0        
      bLtot = 0    
      
      (0...15).each do |_i|
          
          bL = ((65.0 - t_bins[_i]) / (65.0 - t_OD)) * 0.77 * dHR
          
          q_1 = q_H1_1_net + (q_H0_1_net - q_H1_1_net) / (62.0 - 47.0) * (t_bins[_i] - 47.0)
          p_1 = p_H1_1 + (p_H0_1 - p_H1_1) / (62.0 - 47.0) * (t_bins[_i] - 47.0)
          
          if t_bins[_i] <= 17.0 or t_bins[_i] >=45.0
              q_2 = q_H3_2_net + (q_H1_2_net - q_H3_2_net) * (t_bins[_i] - 17.0) / (47.0 - 17.0)
              p_2 = p_H3_2 + (p_H1_2 - p_H3_2) * (t_bins[_i] - 17.0) / (47.0 - 17.0)
          else
              q_2 = q_H3_2_net + (q_H35_2 - q_H3_2_net) * (t_bins[_i] - 17) / (35.0 - 17.0)
              p_2 = p_H3_2 + (p_H35_2 - p_H3_2) * (t_bins[_i] - 17.0) / (35.0 - 17.0)
          end
                  
          if t_bins[_i] <= t_off
              delta = 0
          elsif t_bins[_i] >= t_on
              delta = 1.0
          else
              delta = 0.5        
          end
          
          if bL <= q_1
              x_1 = bL / q_1
              e_Tj_n = delta * x_1 * p_1 * frac_hours[_i] / (1.0 - c_d * (1.0 - x_1))
          elsif q_1 < bL and bL <= q_2
              cop_T_j = a + b * t_bins[_i] + c * t_bins[_i]**2
              e_Tj_n = delta * frac_hours[_i] * bL / cop_T_j + (1.0 - delta) * bL * (frac_hours[_i])
          else
              e_Tj_n = delta * frac_hours[_i] * p_2 + frac_hours[_i] * (bL - delta *  q_2)
          end
                  
          bLtot = bLtot + frac_hours[_i] * bL
          etot = etot + e_Tj_n
      end

      hspf = bLtot / UnitConversions.convert(etot,"Btu/hr","W")    
      return hspf
    end    

end