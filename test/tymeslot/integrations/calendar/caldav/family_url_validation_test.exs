defmodule Tymeslot.Integrations.Calendar.CalDAV.FamilyUrlValidationTest do
  # Every CalDAV-family member gives the same verdict on the same server URL,
  # except that a member with a fixed address accepts that address alone.
  # The verdicts are written out per member, so a member that drifts back to
  # validation of its own fails its rows here.
  #
  # Not async: the private-address opt-out is application config.
  use ExUnit.Case, async: false

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :security

  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]

  alias Tymeslot.Integrations.Calendar.CalDAV.Family
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @https "Use HTTPS for non-local calendar servers"
  @private "Private or local network addresses are not allowed"
  @apple "Invalid Apple iCloud URL. The server must be https://caldav.icloud.com."
  @mailbox "Invalid mailbox.org URL. The server must be https://dav.mailbox.org."

  # {url, verdict for a member whose owner enters their own address,
  #  verdict per member with a fixed address}
  @cases [
    {"https://cal.example.com", :ok, apple: @apple, mailbox_org: @mailbox},
    {"http://cal.example.com", @https, apple: @apple, mailbox_org: @mailbox},
    {"https://10.0.0.1", @private, apple: @apple, mailbox_org: @mailbox},
    {"http://169.254.169.254", @private, apple: @apple, mailbox_org: @mailbox},
    {"https://caldav.icloud.com", :ok, apple: :ok, mailbox_org: @mailbox},
    {"https://caldav.icloud.com/", :ok, apple: :ok, mailbox_org: @mailbox},
    {"https://dav.mailbox.org", :ok, apple: @apple, mailbox_org: :ok}
  ]

  test "the members with a fixed address are iCloud and mailbox.org" do
    assert Family.fixed_urls() |> Map.keys() |> Enum.sort() == [:apple, :mailbox_org]
  end

  for member <- Family.members(), {url, open, fixed} <- @cases do
    @member member
    @url url
    @expected Keyword.get(fixed, member, open)

    test "#{member} answers #{url} with #{inspect(@expected)}" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, false)

      assert verdict(@member, @url) == @expected
    end
  end

  describe "with the operator's private-address opt-out" do
    for member <- Family.members() do
      @member member
      @expected Keyword.get([apple: @apple, mailbox_org: @mailbox], member, :ok)

      test "#{member} answers a private server with #{inspect(@expected)}" do
        with_config(:tymeslot, :allow_private_ips_for_calendar, true)

        assert verdict(@member, "http://10.0.0.1:5232") == @expected
      end
    end
  end

  defp verdict(member, url) do
    config = %{base_url: url, username: "user", password: "pass"}

    module = ProviderConfig.get_provider_module(member) || flunk("no module for #{member}")

    case module.validate_config(config) do
      :ok -> :ok
      {:error, message} -> message
    end
  end
end
