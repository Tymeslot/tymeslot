defmodule Tymeslot.Integrations.Calendar.BookingEligibilityTest do
  @moduledoc """
  Pins the predicate every booking-target gate now shares: a read-only
  provider is never eligible, a writable one always is.
  """

  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.BookingEligibility
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  describe "bookable?/1" do
    test "rejects every read-only provider, in either the atom or the string form" do
      for provider <- [:ics_url, :exchange] do
        refute BookingEligibility.bookable?(%{provider: provider})
        refute BookingEligibility.bookable?(%{provider: Atom.to_string(provider)})
      end
    end

    test "accepts every provider that is not read-only" do
      writable =
        Enum.reject(ProviderConfig.all_providers_with_dev(), &ProviderConfig.read_only?/1)

      assert writable != []

      assert Enum.reject(writable, &BookingEligibility.bookable?(%{provider: &1})) == []
    end
  end

  describe "filter_bookable/1" do
    test "drops the read-only integrations and keeps the order of the rest" do
      integrations = [
        %{id: 1, provider: "google"},
        %{id: 2, provider: "exchange"},
        %{id: 3, provider: "caldav"},
        %{id: 4, provider: "ics_url"}
      ]

      assert BookingEligibility.filter_bookable(integrations) == [
               %{id: 1, provider: "google"},
               %{id: 3, provider: "caldav"}
             ]
    end
  end
end
