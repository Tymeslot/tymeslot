defmodule Tymeslot.Integrations.Calendar.Providers.CaldavCommonCredentialsTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon

  @base_client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: [],
    verify_ssl: true,
    provider: :caldav
  }

  # ---------------------------------------------------------------------------
  # Nil / blank credential guard
  # ---------------------------------------------------------------------------

  describe "test_connection/2 credential validation" do
    test "returns {:error, :invalid_credentials} when password is nil" do
      client = %{@base_client | password: nil}

      assert {:error, :invalid_credentials} =
               CaldavCommon.test_connection(client, ip_address: "127.0.0.1")
    end

    test "returns {:error, :invalid_credentials} when username is nil" do
      client = %{@base_client | username: nil}

      assert {:error, :invalid_credentials} =
               CaldavCommon.test_connection(client, ip_address: "127.0.0.1")
    end

    test "returns {:error, :invalid_credentials} when both credentials are nil" do
      client = %{@base_client | username: nil, password: nil}

      assert {:error, :invalid_credentials} =
               CaldavCommon.test_connection(client, ip_address: "127.0.0.1")
    end

    test "returns {:error, :invalid_credentials} when password is an empty string" do
      client = %{@base_client | password: ""}

      assert {:error, :invalid_credentials} =
               CaldavCommon.test_connection(client, ip_address: "127.0.0.1")
    end
  end

  describe "discover_calendars/2 credential validation" do
    test "returns {:error, :invalid_credentials} when password is nil" do
      client = %{@base_client | password: nil}

      assert {:error, :invalid_credentials} =
               CaldavCommon.discover_calendars(client, ip_address: "127.0.0.1")
    end

    test "returns {:error, :invalid_credentials} when username is nil" do
      client = %{@base_client | username: nil}

      assert {:error, :invalid_credentials} =
               CaldavCommon.discover_calendars(client, ip_address: "127.0.0.1")
    end
  end

  describe "check_connectivity/1 credential validation" do
    test "returns {:error, :invalid_credentials} when password is nil" do
      client = %{@base_client | password: nil}

      assert {:error, :invalid_credentials} = CaldavCommon.check_connectivity(client)
    end

    test "returns {:error, :invalid_credentials} when username is nil" do
      client = %{@base_client | username: nil}

      assert {:error, :invalid_credentials} = CaldavCommon.check_connectivity(client)
    end
  end
end
