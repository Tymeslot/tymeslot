defmodule Tymeslot.Infrastructure.ErrorTracking.UnmatchedEventTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  alias Tymeslot.Infrastructure.ErrorTracking.UnmatchedEvent
  alias TymeslotWeb.Components.UserDropdownComponent
  alias TymeslotWeb.DashboardLive

  @kind "Elixir.FunctionClauseError"

  describe "error?/2" do
    test "is true when no handle_event/3 clause of a LiveView matched" do
      assert UnmatchedEvent.error?(
               @kind,
               "no function clause matching in TymeslotWeb.DashboardLive.handle_event/3"
             )
    end

    test "is true for a LiveComponent, and for a message carrying the given arguments" do
      assert UnmatchedEvent.error?(
               @kind,
               "no function clause matching in " <>
                 "TymeslotWeb.Components.UserDropdownComponent.handle_event/3\n\n" <>
                 "The following arguments were given to it: ..."
             )
    end

    test "is false when a matched clause failed calling another function" do
      refute UnmatchedEvent.error?(
               @kind,
               "no function clause matching in TymeslotWeb.DashboardLive.pick/1"
             )
    end

    test "is false for a handle_event/3 of a module that is not a LiveView" do
      refute UnmatchedEvent.error?(@kind, "no function clause matching in Enum.handle_event/3")

      refute UnmatchedEvent.error?(
               @kind,
               "no function clause matching in Tymeslot.NoSuchLiveEverDefined.handle_event/3"
             )
    end

    test "is false for any other kind of error" do
      refute UnmatchedEvent.error?(
               "Elixir.RuntimeError",
               "no function clause matching in TymeslotWeb.DashboardLive.handle_event/3"
             )

      refute UnmatchedEvent.error?("exit", "normal")
    end
  end

  describe "exception?/1" do
    test "applies the same rule to the exception itself" do
      assert UnmatchedEvent.exception?(%FunctionClauseError{
               module: DashboardLive,
               function: :handle_event,
               arity: 3
             })

      assert UnmatchedEvent.exception?(%FunctionClauseError{
               module: UserDropdownComponent,
               function: :handle_event,
               arity: 3
             })

      refute UnmatchedEvent.exception?(%FunctionClauseError{
               module: DashboardLive,
               function: :pick,
               arity: 1
             })

      refute UnmatchedEvent.exception?(%RuntimeError{message: "boom"})
    end
  end
end
