defmodule Tymeslot.Integrations.Calendar.PrivateIpOptOutTest do
  @moduledoc """
  Covers the operator opt-out (`ALLOW_PRIVATE_IPS_FOR_CALENDAR`) across the two
  save-time surfaces a private-network CalDAV URL has to survive: the connect
  form's field validator and the integration changeset.

  Both used to hard-code the private-IP block, so the request-time guard would
  permit a loopback CalDAV server while the URL could never be saved — the
  switch existed but did nothing. These tests pin both halves: blocked by
  default, accepted only when the operator has opted in.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :security

  import Tymeslot.Factory
  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CredentialFields
  alias Tymeslot.Security.SsrfGuard

  @private_url "http://127.0.0.1:5232"
  @public_url "https://caldav.example.com"

  describe "SsrfGuard.allow_private_for_calendar?/0" do
    test "defaults to false" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, false)

      refute SsrfGuard.allow_private_for_calendar?()
    end

    test "reflects the operator opt-in" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)

      assert SsrfGuard.allow_private_for_calendar?()
    end
  end

  describe "CredentialFields.validate_calendar_url/1" do
    test "rejects a private address while the opt-out is off" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, false)

      assert {:error, message} = CredentialFields.validate_calendar_url(@private_url)
      assert message =~ "Private or local network"
    end

    test "accepts a private address once the operator opts in" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)

      assert :ok = CredentialFields.validate_calendar_url(@private_url)
    end

    test "still accepts a public HTTPS URL either way" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, false)

      assert :ok = CredentialFields.validate_calendar_url(@public_url)
    end
  end

  describe "CalendarIntegrationSchema.changeset/2 :base_url" do
    test "rejects a private address while the opt-out is off" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, false)

      changeset = changeset_for(@private_url)

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).base_url, &(&1 =~ "Private or local network"))
    end

    test "accepts a private address once the operator opts in" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)

      assert changeset_for(@private_url).valid?
    end

    test "still accepts a public HTTPS URL either way" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, false)

      assert changeset_for(@public_url).valid?
    end
  end

  # The form and the changeset are separate gates on the same value, so an
  # opted-in operator must clear both for the switch to be usable at all.
  test "an opted-in operator can validate and persist a loopback CalDAV server" do
    with_config(:tymeslot, :allow_private_ips_for_calendar, true)

    assert :ok = CredentialFields.validate_calendar_url(@private_url)
    assert {:ok, integration} = Repo.insert(changeset_for(@private_url))
    assert integration.base_url == @private_url
  end

  defp changeset_for(base_url) do
    user = insert(:user)

    CalendarIntegrationSchema.changeset(%CalendarIntegrationSchema{}, %{
      name: "Local CalDAV",
      provider: "caldav",
      base_url: base_url,
      username: "tester",
      password: "pw",
      user_id: user.id
    })
  end
end
