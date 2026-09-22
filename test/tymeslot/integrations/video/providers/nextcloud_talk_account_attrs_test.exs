defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalkAccountAttrsTest do
  @moduledoc """
  How a Nextcloud Talk integration's server, login name and app password are
  normalised before one is created or edited, and the account key they make.
  """

  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider

  @talk_config %{
    base_url: "https://cloud.example.com",
    client_id: "organiser",
    client_secret: "Abcde-Fghij-Klmno-Pqrst-Uvwxy"
  }

  describe "account_attrs/1" do
    test "trims the server and login and keys the account on both" do
      attrs =
        NextcloudTalkProvider.account_attrs(%{
          name: "Team Talk",
          base_url: " https://cloud.example.com/ ",
          client_id: " organiser "
        })

      assert attrs.base_url == "https://cloud.example.com"
      assert attrs.client_id == "organiser"
      assert attrs.provider_account_id == "https://cloud.example.com||organiser"
      assert attrs.name == "Team Talk"
    end

    test "makes one account of a server written with a capitalised host or its default port" do
      for server <- [
            "https://Cloud.Example.com",
            "https://cloud.example.com:443/",
            "HTTPS://CLOUD.example.COM:443"
          ] do
        assert %{
                 base_url: "https://cloud.example.com",
                 provider_account_id: "https://cloud.example.com||organiser"
               } =
                 NextcloudTalkProvider.account_attrs(%{base_url: server, client_id: "organiser"})
      end

      assert %{base_url: "http://cloud.example.com/nc"} =
               NextcloudTalkProvider.account_attrs(%{
                 base_url: "http://Cloud.example.com:80/nc",
                 client_id: "organiser"
               })
    end

    test "keeps a port that is not the default and the case of the path" do
      assert %{base_url: "https://cloud.example.com:8443/NextCloud"} =
               NextcloudTalkProvider.account_attrs(%{
                 base_url: "https://Cloud.example.com:8443/NextCloud/",
                 client_id: "organiser"
               })

      assert %{base_url: "http://cloud.example.com:443"} =
               NextcloudTalkProvider.account_attrs(%{
                 base_url: "http://cloud.example.com:443",
                 client_id: "organiser"
               })
    end

    # The provider refuses these with its own messages, so normalising must
    # not hide what it looks for.
    test "leaves a query, a fragment or a login in the address for validation to refuse" do
      for server <- [
            "https://cloud.example.com/?a=b",
            "https://cloud.example.com/#top",
            "https://user:pass@cloud.example.com"
          ] do
        attrs = NextcloudTalkProvider.account_attrs(%{base_url: server, client_id: "organiser"})
        assert attrs.base_url == server
        assert {:error, _message} = NextcloudTalkProvider.validate_config(attrs)
      end
    end

    test "trims the app password and leaves one that is not text alone" do
      assert %{client_secret: "Abcde-Fghij"} =
               NextcloudTalkProvider.account_attrs(%{
                 @talk_config
                 | client_secret: " Abcde-Fghij "
               })

      assert %{client_secret: 12_345} =
               NextcloudTalkProvider.account_attrs(%{@talk_config | client_secret: 12_345})
    end
  end
end
