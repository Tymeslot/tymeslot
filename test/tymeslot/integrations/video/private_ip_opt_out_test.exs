defmodule Tymeslot.Integrations.Video.PrivateIpOptOutTest do
  @moduledoc """
  Covers the operator opt-out (`ALLOW_PRIVATE_IPS_FOR_VIDEO`) on the save-time
  surface every private-network video URL has to survive: the integration
  changeset.

  It used to hard-code the private-IP block, so an operator who had opted into
  private video hosts could reach one at request time but could never store its
  URL — the same half-wired shape the calendar switch was fixed for. These tests
  pin both halves: blocked by default, accepted only after opting in.

  The request-time half lives in
  `Tymeslot.Integrations.Video.Providers.CustomProviderSsrfTest`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :security

  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Security.SsrfGuard

  @private_url "http://192.168.1.10:8443/room-42"
  @public_url "https://meet.example.com/room-42"

  setup do
    with_config(:tymeslot, :allow_private_ips_for_calendar, false)
    with_config(:tymeslot, :allow_private_ips_for_video, false)
    :ok
  end

  describe "SsrfGuard.allow_private_for_video?/0" do
    test "defaults to false" do
      refute SsrfGuard.allow_private_for_video?()
    end

    test "reflects the operator opt-in" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      assert SsrfGuard.allow_private_for_video?()
    end

    test "is still satisfied by the calendar switch, which shipped covering video" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)

      assert SsrfGuard.allow_private_for_video?()
    end

    test "does not work in reverse: relaxing video leaves calendar blocked" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      refute SsrfGuard.allow_private_for_calendar?()
    end
  end

  describe "changeset/2 :custom_meeting_url" do
    test "rejects a private address while the opt-out is off" do
      changeset = custom_changeset(@private_url)

      refute changeset.valid?

      assert Enum.any?(
               errors_on(changeset).custom_meeting_url,
               &(&1 =~ "Private or local network")
             )
    end

    test "accepts a private address once the operator opts in" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      assert custom_changeset(@private_url).valid?
    end

    test "still accepts a public HTTPS URL either way" do
      assert custom_changeset(@public_url).valid?
    end
  end

  describe "changeset/2 :base_url (self-hosted MiroTalk)" do
    test "rejects a private address while the opt-out is off" do
      changeset = mirotalk_changeset("http://192.168.1.10:3000")

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).base_url, &(&1 =~ "Private or local network"))
    end

    test "accepts a private address once the operator opts in" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)

      assert mirotalk_changeset("http://192.168.1.10:3000").valid?
    end
  end

  test "an opted-in operator can persist a meeting server on an internal network" do
    with_config(:tymeslot, :allow_private_ips_for_video, true)

    assert {:ok, integration} = Repo.insert(custom_changeset(@private_url))
    assert integration.custom_meeting_url == @private_url
  end

  defp custom_changeset(url) do
    VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, %{
      name: "Internal Jitsi",
      provider: "custom",
      custom_meeting_url: url,
      user_id: insert(:user).id
    })
  end

  defp mirotalk_changeset(url) do
    VideoIntegrationSchema.changeset(%VideoIntegrationSchema{}, %{
      name: "Internal MiroTalk",
      provider: "mirotalk",
      base_url: url,
      api_key: "test-key",
      user_id: insert(:user).id
    })
  end
end
