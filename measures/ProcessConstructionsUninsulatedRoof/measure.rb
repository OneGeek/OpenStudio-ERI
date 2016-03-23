#see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

require "#{File.dirname(__FILE__)}/resources/util"
require "#{File.dirname(__FILE__)}/resources/constants"
require "#{File.dirname(__FILE__)}/resources/geometry"

#start the measure
class ProcessConstructionsUninsulatedRoof < OpenStudio::Ruleset::ModelUserScript

  #define the name that a user will see, this method may be deprecated as
  #the display name in PAT comes from the name field in measure.xml
  def name
    return "Set Residential Uninsulated Roof Construction"
  end
  
  def description
    return "This measure assigns a construction to uninsulated roofs."
  end
  
  def modeler_description
    return "Calculates and assigns material layer properties of uninsulated constructions for roofs of unfinished spaces (e.g., garage roof), excluding attics."
  end   
  
  #define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Ruleset::OSArgumentVector.new

    return args
  end #end the arguments method

  #define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)
    
    #use the built-in error checking 
    if not runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # Unfinished space (e.g., garage) roof
    spaces = Geometry.get_non_attic_unfinished_roof_spaces(model)
    surfaces = []
    spaces.each do |space|
        space.surfaces.each do |surface|
            if surface.surfaceType.downcase == "roofceiling" and surface.outsideBoundaryCondition.downcase == "outdoors"
                surfaces << surface
            end
        end
    end
    
    # Continue if no applicable surfaces
    if surfaces.empty?
      runner.registerAsNotApplicable("Measure not applied because no applicable surfaces were found.")
      return true
    end   
    
    # Define materials
    mat_cavity = Material.AirCavity(Material.Stud2x4.thick_in)
    mat_framing = Material.new(name=nil, thick_in=Material.Stud2x4.thick_in, mat_base=BaseMaterial.Wood)

    # Set paths
    path_fracs = [Constants.DefaultFramingFactorCeiling, 1 - Constants.DefaultFramingFactorCeiling]
    
    # Define construction
    roof_const = Construction.new(path_fracs)
    roof_const.addlayer(Material.AirFilmOutside, false)
    roof_const.addlayer(Material.DefaultRoofMaterial, false) # roof material added in separate measure
    roof_const.addlayer(Material.DefaultRoofSheathing, false) # sheathing added in separate measure
    roof_const.addlayer([mat_framing, mat_cavity], true, "StudAndAirRoof")
    roof_const.addlayer(Material.AirFilmRoof(Geometry.calculate_avg_roof_pitch(spaces)), false)

    # Create and assign construction to surfaces
    if not roof_const.create_and_assign_constructions(surfaces, runner, model, name="UnfinUninsExtRoof")
        return false
    end

    # Remove any materials which aren't used in any constructions
    HelperMethods.remove_unused_materials_and_constructions(model, runner)
    
    return true
 
  end #end the run method

end #end the measure

#this allows the measure to be use by the application
ProcessConstructionsUninsulatedRoof.new.registerWithApplication