defmodule Tymeslot.Integrations.Calendar.DisplayHelpersTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.DisplayHelpers

  @unreachable_advice "only reachable from your organisation's network or over a VPN"

  describe "connection_error_message/2" do
    test "gives a timeout from a server its owner runs the unreachable-server advice" do
      for provider <- ["caldav", "nextcloud", "radicale", :zimbra, "exchange"] do
        assert DisplayHelpers.connection_error_message(:timeout, provider) =~ @unreachable_advice
      end
    end

    test "keeps the generic wording for a provider with a fixed address" do
      assert DisplayHelpers.connection_error_message(:timeout, "apple") ==
               DisplayHelpers.connection_error_message(:timeout)
    end

    test "keeps the generic wording for a reason with no provider-specific advice" do
      assert DisplayHelpers.connection_error_message(:network_error, "caldav") ==
               DisplayHelpers.connection_error_message(:network_error)
    end

    test "keeps the generic wording for an unknown provider" do
      assert DisplayHelpers.connection_error_message(:timeout, "nonexistent") ==
               DisplayHelpers.connection_error_message(:timeout)
    end
  end
end
