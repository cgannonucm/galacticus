!! Copyright 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018,
!!           2019, 2020, 2021, 2022, 2023, 2024
!!    Andrew Benson <abenson@carnegiescience.edu>
!!
!! This file is part of Galacticus.
!!
!!    Galacticus is free software: you can redistribute it and/or modify
!!    it under the terms of the GNU General Public License as published by
!!    the Free Software Foundation, either version 3 of the License, or
!!    (at your option) any later version.
!!
!!    Galacticus is distributed in the hope that it will be useful,
!!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!!    GNU General Public License for more details.
!!
!!    You should have received a copy of the GNU General Public License
!!    along with Galacticus.  If not, see <http://www.gnu.org/licenses/>.

!!{
Contains a module which implements the simple black hole node component.
!!}

module Node_Component_Black_Hole_Simple
  !!{
  Implements the simple black hole node component.
  !!}
  use :: Black_Hole_Binary_Mergers     , only : blackHoleBinaryMergerClass
  use :: Black_Hole_Accretion_Rates    , only : blackHoleAccretionRateClass
  use :: Cooling_Radii                 , only : coolingRadiusClass
  use :: Dark_Matter_Halo_Scales       , only : darkMatterHaloScaleClass
  implicit none
  private
  public :: Node_Component_Black_Hole_Simple_Initialize         , Node_Component_Black_Hole_Simple_Scale_Set        , &
       &    Node_Component_Black_Hole_Simple_Thread_Uninitialize, Node_Component_Black_Hole_Simple_Thread_Initialize, &
       &    Node_Component_Black_Hole_Simple_State_Store        , Node_Component_Black_Hole_Simple_State_Restore    , &
       &    Node_Component_Black_Hole_Simple_Rate_Compute 

  !![
  <component>
   <class>blackHole</class>
   <name>simple</name>
   <isDefault>false</isDefault>
   <properties>
    <property>
      <name>mass</name>
      <type>double</type>
      <rank>0</rank>
      <attributes isSettable="true" isGettable="true" isEvolvable="true" />
      <classDefault>defaultBlackHoleComponent%massSeed()</classDefault>
      <output unitsInSI="massSolar" comment="Mass of the black hole."/>
    </property>
    <property>
      <name>massSeed</name>
      <type>double</type>
      <rank>0</rank>
      <attributes isSettable="false" isGettable="true" isEvolvable="false" isVirtual="true" isDeferred="get" />
    </property>
   </properties>
   <bindings>
      <binding method="enclosedMass" function="Node_Component_Black_Hole_Simple_Enclosed_Mass" bindsTo="component" />
      <binding method="acceleration" function="Node_Component_Black_Hole_Simple_Acceleration"  bindsTo="component" />
      <binding method="tidalTensor"  function="Node_Component_Black_Hole_Simple_Tidal_Tensor"  bindsTo="component" />
   </bindings>
   <functions>objects.nodes.components.black_hole.simple.bound_functions.inc</functions>
  </component>
  !!]

  ! Objects used by this component.
  class(darkMatterHaloScaleClass       ), pointer :: darkMatterHaloScale_
  class(coolingRadiusClass             ), pointer :: coolingRadius_
  class(blackHoleBinaryMergerClass     ), pointer :: blackHoleBinaryMerger_
  class(blackHoleAccretionRateClass    ), pointer :: blackHoleAccretionRate_
  !$omp threadprivate(darkMatterHaloScale_,blackHoleAccretionRate_,coolingRadius_,blackHoleBinaryMerger_)

  ! Seed mass for black holes.
  double precision :: massSeed

  ! Feedback parameters.
  double precision :: efficiencyHeating, efficiencyWind
  logical          :: heatsHotHalo

  ! A threadprivate object used to track to which thread events are attached.
  integer :: thread
  !$omp threadprivate(thread)

contains

  !![
  <nodeComponentInitializationTask>
   <unitName>Node_Component_Black_Hole_Simple_Initialize</unitName>
  </nodeComponentInitializationTask>
  !!]
  subroutine Node_Component_Black_Hole_Simple_Initialize(parameters)
    !!{
    Initializes the simple black hole node component module.
    !!}
    use :: Galacticus_Nodes, only : nodeComponentBlackHoleSimple
    use :: Input_Parameters, only : inputParameter              , inputParameters
    implicit none
    type(inputParameters             ), intent(inout) :: parameters
    type(nodeComponentBlackHoleSimple)                :: blackHoleSimple
    type(inputParameters             )                :: subParameters

    ! Bind deferred functions.
    call blackHoleSimple%massSeedFunction(Node_Component_Black_Hole_Simple_Seed_Mass)
    ! Find our parameters.
    subParameters=parameters%subParameters('componentBlackHole')
    ! Get the seed mass
    !![
    <inputParameter>
      <name>massSeed</name>
      <source>subParameters</source>
      <defaultValue>100.0d0</defaultValue>
      <description>The mass of the seed black hole placed at the center of each newly formed galaxy.</description>
    </inputParameter>
    !!]
    ! Options controlling AGN feedback.
    !![
    <inputParameter>
      <name>heatsHotHalo</name>
      <defaultValue>.true.</defaultValue>
      <description>Specifies whether or not the black hole should heat the hot halo.</description>
      <source>subParameters</source>
    </inputParameter>
    !!]
    if (heatsHotHalo) then
       !![
       <inputParameter>
         <name>efficiencyHeating</name>
         <defaultValue>1.0d-3</defaultValue>
         <description>The efficiency with which accretion onto a black hole heats the hot halo.</description>
         <source>subParameters</source>
       </inputParameter>
       !!]
    else
       efficiencyHeating=0.0d0
    end if
    ! Get options controlling winds.
    !![
    <inputParameter>
      <name>efficiencyWind</name>
      <defaultValue>2.2157d-3</defaultValue>
      <description>The efficiency of the black hole accretion-driven wind.</description>
      <source>subParameters</source>
    </inputParameter>
    !!]
    return
  end subroutine Node_Component_Black_Hole_Simple_Initialize

  !![
  <nodeComponentThreadInitializationTask>
   <unitName>Node_Component_Black_Hole_Simple_Thread_Initialize</unitName>
  </nodeComponentThreadInitializationTask>
  !!]
  subroutine Node_Component_Black_Hole_Simple_Thread_Initialize(parameters)
    !!{
    Initializes the tree node random spin module.
    !!}
    use :: Events_Hooks    , only : satelliteMergerEvent     , openMPThreadBindingAtLevel, dependencyRegEx, dependencyDirectionAfter
    use :: Galacticus_Nodes, only : defaultBlackHoleComponent
    use :: Input_Parameters, only : inputParameter           , inputParameters
    implicit none
    type(inputParameters), intent(inout) :: parameters
    type(dependencyRegEx), dimension(1)  :: dependencies
    type(inputParameters)                :: subParameters

    if (defaultBlackHoleComponent%simpleIsActive()) then
       ! Find our parameters.
       subParameters=parameters%subParameters('componentBlackHole')
       !![
       <objectBuilder class="darkMatterHaloScale"    name="darkMatterHaloScale_"    source="subParameters"/>
       <objectBuilder class="coolingRadius"          name="coolingRadius_"          source="subParameters"/>
       <objectBuilder class="blackHoleBinaryMerger"  name="blackHoleBinaryMerger_"  source="subParameters"/>
       <objectBuilder class="blackHoleAccretionRate" name="blackHoleAccretionRate_" source="subParameters"/>
       !!]
       dependencies(1)=dependencyRegEx(dependencyDirectionAfter,'^remnantStructure:')
       call satelliteMergerEvent%attach(thread,satelliteMerger,openMPThreadBindingAtLevel,label='nodeComponentBlackHoleSimple',dependencies=dependencies)
    end if
    return
  end subroutine Node_Component_Black_Hole_Simple_Thread_Initialize

  !![
  <nodeComponentThreadUninitializationTask>
   <unitName>Node_Component_Black_Hole_Simple_Thread_Uninitialize</unitName>
  </nodeComponentThreadUninitializationTask>
  !!]
  subroutine Node_Component_Black_Hole_Simple_Thread_Uninitialize()
    !!{
    Uninitializes the tree node random spin module.
    !!}
    use :: Events_Hooks    , only : satelliteMergerEvent
    use :: Galacticus_Nodes, only : defaultBlackHoleComponent
    implicit none

    if (defaultBlackHoleComponent%simpleIsActive()) then
       !![
       <objectDestructor name="darkMatterHaloScale_"   />
       <objectDestructor name="coolingRadius_"         />
       <objectDestructor name="blackHoleBinaryMerger_" />
       <objectDestructor name="blackHoleAccretionRate_"/>
       !!]
       if (satelliteMergerEvent%isAttached(thread,satelliteMerger)) call satelliteMergerEvent%detach(thread,satelliteMerger)
    end if
    return
  end subroutine Node_Component_Black_Hole_Simple_Thread_Uninitialize

  !![
  <scaleSetTask>
   <unitName>Node_Component_Black_Hole_Simple_Scale_Set</unitName>
  </scaleSetTask>
  !!]
  subroutine Node_Component_Black_Hole_Simple_Scale_Set(node)
    !!{
    Set scales for properties of {\normalfont \ttfamily node}.
    !!}
    use :: Galacticus_Nodes, only : nodeComponentBlackHole   , nodeComponentBlackHoleSimple, nodeComponentSpheroid, treeNode, &
         &                          defaultBlackHoleComponent
    implicit none
    type            (treeNode              ), intent(inout), pointer :: node
    class           (nodeComponentBlackHole)               , pointer :: blackHole
    class           (nodeComponentSpheroid )               , pointer :: spheroid
    double precision                        , parameter              :: massScaleAbsolute=1.0d+0, massScaleRelative=1.0d-3

    ! Check if we are the default method.
    if (.not.defaultBlackHoleComponent%simpleIsActive()) return
    ! Get the black hole component.
    blackHole => node%blackHole()
    ! Ensure that it is of the standard class.
    select type (blackHole)
    class is (nodeComponentBlackHoleSimple)
       ! Get the spheroid component.
       spheroid => node%spheroid()
       ! Set scale for mass.
       call blackHole%massScale(                                                             &
            &                   max(                                                         &
            &                                                 blackHole%massSeed         (), &
            &                       max(                                                     &
            &                               massScaleRelative*spheroid %massStellar      (), &
            &                           max(                                                 &
            &                                                           massScaleAbsolute  , &
            &                                                 blackHole%mass             ()  &
            &                              )                                                 &
            &                          )                                                     &
            &                      )                                                         &
            &                  )
    end select
    return
  end subroutine Node_Component_Black_Hole_Simple_Scale_Set

  !![
  <rateComputeTask>
   <unitName>Node_Component_Black_Hole_Simple_Rate_Compute</unitName>
  </rateComputeTask>
  !!]
  subroutine Node_Component_Black_Hole_Simple_Rate_Compute(node,interrupt,interruptProcedure,propertyType)
    !!{
    Compute the black hole mass rate of change.
    !!}
    use :: Galacticus_Nodes            , only : defaultBlackHoleComponent, interruptTask        , nodeComponentBlackHole, nodeComponentBlackHoleSimple, &
          &                                     nodeComponentHotHalo     , nodeComponentSpheroid, propertyInactive      , treeNode
    use :: Numerical_Constants_Physical, only : speedLight
    use :: Numerical_Constants_Prefixes, only : kilo
    implicit none
    type            (treeNode                ), intent(inout)          :: node
    logical                                   , intent(inout)          :: interrupt
    procedure       (interruptTask           ), intent(inout), pointer :: interruptProcedure
    integer                                   , intent(in   )          :: propertyType
    class           (nodeComponentBlackHole  )               , pointer :: blackHole
    class           (nodeComponentSpheroid   )               , pointer :: spheroid
    class           (nodeComponentHotHalo    )               , pointer :: hotHalo
    double precision                          , parameter              :: coolingRadiusFractionalTransitionMinimum=0.9d0
    double precision                          , parameter              :: coolingRadiusFractionalTransitionMaximum=1.0d0
    double precision                                                   :: coolingRadiusFractional                       , couplingEfficiency   , &
         &                                                                energyInputRate                               , heatingRate          , &
         &                                                                massAccretionRate                             , restMassAccretionRate, &
         &                                                                accretionRateSpheroid                         , accretionRateHotHalo , &
         &                                                                x

    ! Return immediately if inactive variables are requested.
    if (propertyInactive(propertyType)) return
    if (defaultBlackHoleComponent%simpleIsActive()) then

       ! Get the black hole component.
       blackHole => node%blackHole()

       ! Find the rate of rest mass accretion onto the black hole.
       call blackHoleAccretionRate_%rateAccretion(blackHole,accretionRateSpheroid,accretionRateHotHalo)
       restMassAccretionRate=+accretionRateSpheroid &
            &                +accretionRateHotHalo

       ! Finish if there is no accretion.
       if (restMassAccretionRate <= 0.0d0) return

       ! Find the rate of increase in mass of the black hole.
       massAccretionRate=restMassAccretionRate*max((1.0d0-efficiencyHeating-efficiencyWind),0.0d0)

       ! Detect black hole component type.
       select type (blackHole)
       type is (nodeComponentBlackHole)
          ! Generic type - interrupt and create a simple black hole if accretion rate is non-zero.
          if (massAccretionRate /= 0.0d0) then
             interrupt=.true.
             interruptProcedure => Node_Component_Black_Hole_Simple_Create
          end if
          return
       class is (nodeComponentBlackHoleSimple)
          ! Get the spheroid component.
          spheroid => node%spheroid()
          ! Add accretion to the black hole.
          call blackHole%massRate       (     massAccretionRate)
          ! Remove the accreted mass from the spheroid component.
          call spheroid %massGasSinkRate(-restMassAccretionRate)
          ! Add heating to the hot halo component.
          if (heatsHotHalo) then
             ! Compute jet coupling efficiency based on whether halo is cooling quasistatically.
             coolingRadiusFractional=+coolingRadius_      %      radius(node) &
                  &                  /darkMatterHaloScale_%radiusVirial(node)
             if      (coolingRadiusFractional < coolingRadiusFractionalTransitionMinimum) then
                couplingEfficiency=1.0d0
             else if (coolingRadiusFractional > coolingRadiusFractionalTransitionMaximum) then
                couplingEfficiency=0.0d0
             else
                x=      (coolingRadiusFractional                 -coolingRadiusFractionalTransitionMinimum) &
                     & /(coolingRadiusFractionalTransitionMaximum-coolingRadiusFractionalTransitionMinimum)
                couplingEfficiency=x**2*(2.0d0*x-3.0d0)+1.0d0
             end if
             ! Compute the heating rate.
             heatingRate=couplingEfficiency*efficiencyHeating*restMassAccretionRate*(speedLight/kilo)**2
             ! Pipe this power to the hot halo.
             hotHalo => node%hotHalo()
             call hotHalo%heatSourceRate(heatingRate,interrupt,interruptProcedure)
          end if
          ! Add energy to the spheroid component.
          if (efficiencyWind > 0.0d0) then
             ! Compute the energy input and send it down the spheroid gas energy input pipe.
             energyInputRate=efficiencyWind*restMassAccretionRate*(speedLight/kilo)**2
             call spheroid%energyGasInputRate(energyInputRate)
          end if
       end select
    end if
    return
  end subroutine Node_Component_Black_Hole_Simple_Rate_Compute

  subroutine satelliteMerger(self,node)
    !!{
    Merge (instantaneously) any simple black hole associated with {\normalfont \ttfamily node} before it merges with its host halo.
    !!}
    use :: Galacticus_Nodes, only : nodeComponentBlackHole, treeNode
    implicit none
    class           (*                     ), intent(inout) :: self
    type            (treeNode              ), intent(inout) :: node
    type            (treeNode              ), pointer       :: nodeHost
    class           (nodeComponentBlackHole), pointer       :: blackHoleHost   , blackHole
    double precision                                        :: massBlackHoleNew, spinBlackHoleNew
    !$GLC attributes unused :: self
    
    ! Find the node to merge with.
    nodeHost      => node    %mergesWith(                 )
    ! Get the black holes.
    blackHole     => node    %blackHole (autoCreate=.true.)
    blackHoleHost => nodeHost%blackHole (autoCreate=.true.)
    ! Compute the effects of the merger.
    call blackHoleBinaryMerger_%merge(blackHole    %mass(), &
         &                            blackHoleHost%mass(), &
         &                            0.0d0               , &
         &                            0.0d0               , &
         &                            massBlackHoleNew    , &
         &                            spinBlackHoleNew      &
         &                           )
    ! Move the black hole to the host.
    call blackHoleHost%massSet(massBlackHoleNew)
    call blackHole    %massSet(           0.0d0)
    return
  end subroutine satelliteMerger

  subroutine Node_Component_Black_Hole_Simple_Create(node,timeEnd)
    !!{
    Creates a simple black hole component for {\normalfont \ttfamily node}.
    !!}
    use :: Galacticus_Nodes, only : nodeComponentBlackHole, treeNode
    implicit none
    type            (treeNode              ), intent(inout), target   :: node
    double precision                        , intent(in   ), optional :: timeEnd
    class           (nodeComponentBlackHole)               , pointer  :: blackHole
    !$GLC attributes unused :: timeEnd
    
    ! Create the component.
    blackHole => node%blackHole(autoCreate=.true.)
    ! Set the seed mass.
    call blackHole%massSet(massSeed)
    return
  end subroutine Node_Component_Black_Hole_Simple_Create

  double precision function Node_Component_Black_Hole_Simple_Seed_Mass(self)
    !!{
    Return the seed mass for simple black holes.
    !!}
    use :: Galacticus_Nodes, only : nodeComponentBlackHoleSimple
    implicit none
    class(nodeComponentBlackHoleSimple), intent(inout) :: self
    !$GLC attributes unused :: self
    
    Node_Component_Black_Hole_Simple_Seed_Mass=massSeed
    return
  end function Node_Component_Black_Hole_Simple_Seed_Mass

  !![
  <stateStoreTask>
   <unitName>Node_Component_Black_Hole_Simple_State_Store</unitName>
  </stateStoreTask>
  !!]
  subroutine Node_Component_Black_Hole_Simple_State_Store(stateFile,gslStateFile,stateOperationID)
    !!{
    Store object state,
    !!}
    use            :: Display      , only : displayMessage, verbosityLevelInfo
    use, intrinsic :: ISO_C_Binding, only : c_ptr         , c_size_t
    implicit none
    integer          , intent(in   ) :: stateFile
    integer(c_size_t), intent(in   ) :: stateOperationID
    type   (c_ptr   ), intent(in   ) :: gslStateFile

    call displayMessage('Storing state for: componentBlackHole -> simple',verbosity=verbosityLevelInfo)
    !![
    <stateStore variables="darkMatterHaloScale_ coolingRadius_ blackHoleBinaryMerger_"/>
    !!]
    return
  end subroutine Node_Component_Black_Hole_Simple_State_Store

  !![
  <stateRetrieveTask>
   <unitName>Node_Component_Black_Hole_Simple_State_Restore</unitName>
  </stateRetrieveTask>
  !!]
  subroutine Node_Component_Black_Hole_Simple_State_Restore(stateFile,gslStateFile,stateOperationID)
    !!{
    Retrieve object state.
    !!}
    use            :: Display      , only : displayMessage, verbosityLevelInfo
    use, intrinsic :: ISO_C_Binding, only : c_ptr         , c_size_t
    implicit none
    integer          , intent(in   ) :: stateFile
    integer(c_size_t), intent(in   ) :: stateOperationID
    type   (c_ptr   ), intent(in   ) :: gslStateFile

    call displayMessage('Retrieving state for: componentBlackHole -> simple',verbosity=verbosityLevelInfo)
    !![
    <stateRestore variables="darkMatterHaloScale_ coolingRadius_ blackHoleBinaryMerger_"/>
    !!]
    return
  end subroutine Node_Component_Black_Hole_Simple_State_Restore

end module Node_Component_Black_Hole_Simple
