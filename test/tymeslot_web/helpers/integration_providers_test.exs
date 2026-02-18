defmodule TymeslotWeb.Helpers.IntegrationProvidersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias TymeslotWeb.Helpers.IntegrationProviders

  describe "reason_to_form_errors/1" do
    test "maps 'Invalid API key' case-insensitively" do
      assert %{api_key: "Invalid API key"} =
               IntegrationProviders.reason_to_form_errors("Invalid API key")

      assert %{api_key: "invalid api key"} =
               IntegrationProviders.reason_to_form_errors("invalid api key")

      assert %{api_key: "INVALID API KEY"} =
               IntegrationProviders.reason_to_form_errors("INVALID API KEY")
    end

    test "maps 'Authentication failed' case-insensitively" do
      assert %{api_key: "Authentication failed"} =
               IntegrationProviders.reason_to_form_errors("Authentication failed")

      assert %{api_key: "AUTHENTICATION FAILED"} =
               IntegrationProviders.reason_to_form_errors("AUTHENTICATION FAILED")
    end

    test "maps URL-related errors case-insensitively to base_url" do
      assert %{base_url: "Invalid URL"} =
               IntegrationProviders.reason_to_form_errors("Invalid URL")

      assert %{base_url: "domain not found"} =
               IntegrationProviders.reason_to_form_errors("domain not found")

      assert %{base_url: "ENDPoint error"} =
               IntegrationProviders.reason_to_form_errors("ENDPoint error")
    end

    test "defaults to base_url for unknown errors" do
      assert %{base_url: "Some weird error"} =
               IntegrationProviders.reason_to_form_errors("Some weird error")

      assert %{base_url: "Connection validation failed"} =
               IntegrationProviders.reason_to_form_errors(nil)
    end
  end
end
