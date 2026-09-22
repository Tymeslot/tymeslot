defmodule Tymeslot.Integrations.Video.AccountKeyTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :video

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Video.AccountKey
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  describe "from_url/1" do
    for {label, typed, key} <- [
          {"keeps an address already in its normal form", "https://meet.example.com",
           "https://meet.example.com"},
          {"drops a trailing slash", "https://meet.example.com/", "https://meet.example.com"},
          {"drops every trailing slash of a path", "https://meet.example.com/team//",
           "https://meet.example.com/team"},
          {"lower-cases the scheme and host", "HTTPS://Meet.Example.COM",
           "https://meet.example.com"},
          {"keeps the case of the path", "https://meet.example.com/Team/",
           "https://meet.example.com/Team"},
          {"drops the default https port", "https://meet.example.com:443/",
           "https://meet.example.com"},
          {"drops the default http port", "http://meet.example.com:80",
           "http://meet.example.com"},
          {"keeps any other port", "https://meet.example.com:8443/",
           "https://meet.example.com:8443"},
          {"keeps the query string", "https://Zoom.us/j/123/?pwd=AbC",
           "https://zoom.us/j/123?pwd=AbC"},
          {"trims surrounding spaces", "  https://meet.example.com/  ",
           "https://meet.example.com"},
          {"trims only a trailing slash from what is not an address", "meet.example.com/",
           "meet.example.com"}
        ] do
      test label do
        assert AccountKey.from_url(unquote(typed)) == unquote(key)
      end
    end

    test "has no key for a blank or missing address" do
      assert AccountKey.from_url("  ") == nil
      assert AccountKey.from_url(nil) == nil
    end
  end

  describe "check_free/4" do
    setup do
      %{user: insert(:user)}
    end

    test "refuses a key an integration of the user holds written another way", %{user: user} do
      insert(:video_integration,
        user: user,
        provider: "mirotalk",
        provider_account_id: "HTTPS://Talk.Example.com/"
      )

      assert {:error, :duplicate_integration} =
               AccountKey.check_free(user.id, "mirotalk", "https://talk.example.com", nil)
    end

    test "refuses an inactive integration's key too", %{user: user} do
      insert(:video_integration,
        user: user,
        provider: "jitsi",
        provider_account_id: "https://meet.example.com",
        is_active: false
      )

      assert {:error, :duplicate_integration} =
               AccountKey.check_free(user.id, :jitsi, "https://meet.example.com", nil)
    end

    test "leaves out the integration being edited", %{user: user} do
      own =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          provider_account_id: "https://talk.example.com"
        )

      assert :ok = AccountKey.check_free(user.id, "mirotalk", "https://talk.example.com", own.id)
    end

    test "ignores another user's and another provider's integrations", %{user: user} do
      insert(:video_integration,
        provider: "mirotalk",
        provider_account_id: "https://a.example.com"
      )

      insert(:video_integration,
        user: user,
        provider: "jitsi",
        provider_account_id: "https://a.example.com"
      )

      assert :ok = AccountKey.check_free(user.id, "mirotalk", "https://a.example.com", nil)
    end

    test "compares a key that is not an address exactly", %{user: user} do
      insert(:video_integration,
        user: user,
        provider: "nextcloud_talk",
        provider_account_id: "https://cloud.example.com||Organiser"
      )

      assert :ok =
               AccountKey.check_free(
                 user.id,
                 "nextcloud_talk",
                 "https://cloud.example.com||organiser",
                 nil
               )

      assert {:error, :duplicate_integration} =
               AccountKey.check_free(
                 user.id,
                 "nextcloud_talk",
                 "https://cloud.example.com||Organiser",
                 nil
               )
    end
  end

  describe "refuse_taken_key/1" do
    test "turns the active account index's refusal into the duplicate refusal" do
      user = insert(:user)
      attrs = %{user_id: user.id, provider: "custom", name: "Link"}
      url = "https://meet.example.com/room"
      key_attrs = Map.merge(attrs, %{custom_meeting_url: url, provider_account_id: url})

      assert {:ok, _first} = VideoIntegrationQueries.create(key_attrs)

      assert {:error, :duplicate_integration} =
               key_attrs |> VideoIntegrationQueries.create() |> AccountKey.refuse_taken_key()
    end

    test "leaves any other result alone" do
      changeset =
        Changeset.add_error(Changeset.change(%VideoIntegrationSchema{}), :name, "is invalid")

      assert {:error, ^changeset} = AccountKey.refuse_taken_key({:error, changeset})
      assert {:ok, :saved} = AccountKey.refuse_taken_key({:ok, :saved})
    end
  end
end
