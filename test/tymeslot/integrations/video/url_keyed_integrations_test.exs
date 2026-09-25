defmodule Tymeslot.Integrations.Video.UrlKeyedIntegrationsTest do
  @moduledoc """
  MiroTalk, Jitsi and the custom video link are told apart by the address the
  organiser enters. Editing that address moves the integration to the new one,
  so the old address can be connected again and the new one cannot be
  connected twice, and an address written differently but leading to the same
  place counts as the same one.
  """

  # Not async: adding a MiroTalk integration tests its connection through the
  # global HTTP client stub.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :video

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video

  setup :verify_on_exit!

  setup do
    stub(HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: "{}"}}
    end)

    %{user: insert(:user)}
  end

  for {provider, field, old_url, new_url, new_url_variant} <- [
        {:mirotalk, :base_url, "https://p2p-a.example.com", "https://p2p-b.example.com",
         "HTTPS://P2P-B.example.com/"},
        {:jitsi, :base_url, "https://meet-a.example.com", "https://meet-b.example.com",
         "https://Meet-B.Example.com:443/"},
        {:custom, :custom_meeting_url, "https://video.example.com/a",
         "https://video.example.com/b", "https://VIDEO.example.com/b/"}
      ] do
    describe "#{provider}" do
      @describetag provider: provider, field: field

      test "an edited address can be connected again, and the new one cannot be twice",
           ctx do
        {:ok, integration} = connect(ctx, unquote(old_url))

        assert {:ok, edited} = edit(ctx, integration, unquote(new_url))
        assert edited.provider_account_id == unquote(new_url)

        assert {:ok, _again} = connect(ctx, unquote(old_url))
        assert {:error, :duplicate_integration} = connect(ctx, unquote(new_url))
        assert {:error, :duplicate_integration} = connect(ctx, unquote(new_url_variant))
      end

      test "an address with a trailing slash or a capitalised host is the same one",
           ctx do
        {:ok, integration} = connect(ctx, unquote(new_url_variant))

        assert integration.provider_account_id == unquote(new_url)
        assert {:error, :duplicate_integration} = connect(ctx, unquote(new_url))
      end

      test "an edit onto an address another integration holds is refused and saves nothing",
           %{user: user} = ctx do
        {:ok, _held} = connect(ctx, unquote(new_url))
        {:ok, integration} = connect(ctx, unquote(old_url))

        assert {:error, :duplicate_integration} =
                 edit(ctx, integration, unquote(new_url_variant))

        assert {:ok, stored} = Video.get_integration(user.id, integration.id)
        assert Map.fetch!(stored, unquote(field)) == unquote(old_url)
        assert stored.provider_account_id == unquote(old_url)
      end

      test "an edit onto an inactive integration's address is refused too", %{user: user} = ctx do
        {:ok, held} = connect(ctx, unquote(new_url))
        {:ok, _inactive} = Video.toggle_integration(user.id, held.id)
        {:ok, integration} = connect(ctx, unquote(old_url))

        assert {:error, :duplicate_integration} = edit(ctx, integration, unquote(new_url))
      end

      test "the same address written differently leaves the key alone", ctx do
        {:ok, integration} = connect(ctx, unquote(new_url))

        assert {:ok, edited} = edit(ctx, integration, unquote(new_url_variant))
        assert edited.provider_account_id == unquote(new_url)
      end

      test "a key saved as typed before keys were normalised still counts", %{user: user} = ctx do
        insert(:video_integration,
          user: user,
          provider: to_string(unquote(provider)),
          provider_account_id: unquote(new_url_variant)
        )

        assert {:error, :duplicate_integration} = connect(ctx, unquote(new_url))
      end

      test "a submitted key is ignored", %{user: user} = ctx do
        {:ok, integration} = connect(ctx, unquote(old_url))

        assert {:ok, edited} =
                 Video.update_integration(user.id, integration.id, %{
                   name: "Renamed",
                   provider_account_id: "https://elsewhere.example.com"
                 })

        assert edited.provider_account_id == unquote(old_url)
      end
    end
  end

  describe "custom video link query strings" do
    @describetag provider: :custom, field: :custom_meeting_url

    test "personal meeting links differing only in their password are different links",
         ctx do
      assert {:ok, first} = connect(ctx, "https://zoom.us/j/123?pwd=one")
      assert first.provider_account_id == "https://zoom.us/j/123?pwd=one"

      assert {:ok, _second} = connect(ctx, "https://zoom.us/j/123?pwd=two")

      assert {:error, :duplicate_integration} = connect(ctx, "https://Zoom.us/j/123/?pwd=one")
    end

    test "the password keeps its case", ctx do
      assert {:ok, _lower} = connect(ctx, "https://zoom.us/j/123?pwd=abc")
      assert {:ok, _upper} = connect(ctx, "https://zoom.us/j/123?pwd=ABC")
    end
  end

  # The provider and its address field come from the describe's tags.
  defp connect(%{user: user, provider: provider, field: field}, url) do
    attrs = %{:name => "Video #{System.unique_integer([:positive])}", field => url}
    Video.create_integration(user.id, provider, Map.merge(attrs, secret(provider)))
  end

  defp edit(%{user: user, field: field}, integration, url),
    do:
      Video.update_integration(user.id, integration.id, %{:name => integration.name, field => url})

  defp secret(:mirotalk), do: %{api_key: "mirotalk-api-key"}
  defp secret(_provider), do: %{}
end
