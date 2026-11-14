defmodule Tymeslot.EmailSending.DestinationTest do
  @moduledoc "Tests public SMTP address policy independently of transport fixtures."
  use ExUnit.Case, async: false

  @moduletag :emails
  @moduletag :security
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.EmailSending.Destination

  defmodule Resolver do
    @moduledoc false
    @doc false
    @spec resolve_public(String.t(), []) :: term()
    def resolve_public(url, []) do
      send(Application.fetch_env!(:tymeslot, :smtp_destination_test_owner), {:resolved, url})
      Application.fetch_env!(:tymeslot, :smtp_destination_test_result)
    end
  end

  setup do
    with_config(:tymeslot,
      user_smtp_enabled: true,
      dns_resolver_module: Resolver,
      smtp_destination_test_owner: self(),
      smtp_destination_test_result: {:ok, [{93, 184, 216, 34}]}
    )

    :ok
  end

  test "disabled feature refuses before DNS resolution" do
    with_config(:tymeslot, user_smtp_enabled: false)

    assert {:error, :feature_disabled} = Destination.resolve("smtp.example.com", 587)
    refute_received {:resolved, _url}
  end

  test "returns an approved IPv4 endpoint for the original port" do
    assert {:ok, %{address: {93, 184, 216, 34}, port: 587}} =
             Destination.resolve("smtp.example.com", 587)

    assert_receive {:resolved, "https://smtp.example.com"}
  end

  test "returns a globally routable IPv6 address" do
    address = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}
    with_config(:tymeslot, smtp_destination_test_result: {:ok, [address]})

    assert {:ok, %{address: ^address, port: 465}} = Destination.resolve("smtp.example.com", 465)
  end

  test "rejects the entire DNS answer if one address is nonpublic" do
    for address <- [
          {127, 0, 0, 1},
          {10, 0, 0, 1},
          {169, 254, 169, 254},
          {192, 0, 2, 1},
          {198, 18, 0, 1},
          {224, 0, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0x100, 0, 0, 0, 0, 0, 0, 1},
          {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1},
          {0x2001, 0x10, 0, 0, 0, 0, 0, 1}
        ] do
      with_config(:tymeslot,
        smtp_destination_test_result: {:ok, [{93, 184, 216, 34}, address]}
      )

      assert {:error, :invalid_destination} = Destination.resolve("smtp.example.com", 587)
    end
  end

  test "refuses URLs, internal names, IP literals, and nonstandard ports before DNS" do
    for host <- [
          "localhost",
          "smtp.local",
          "smtp.lan",
          "https://smtp.example.com",
          "user@smtp.example.com",
          "127.0.0.1",
          "[::1]",
          "smtp.example.com:587",
          "smtp.example.com\r\n"
        ] do
      assert {:error, :invalid_settings} = Destination.resolve(host, 587)
    end

    assert {:error, :invalid_settings} = Destination.resolve("smtp.example.com", 25)
    refute_received {:resolved, _url}
  end

  test "empty or failed DNS answers fail closed without leaking resolver messages" do
    for answer <- [{:ok, []}, {:error, "private network details"}] do
      with_config(:tymeslot, smtp_destination_test_result: answer)
      assert {:error, :dns_failed} = Destination.resolve("smtp.example.com", 587)
    end
  end
end
