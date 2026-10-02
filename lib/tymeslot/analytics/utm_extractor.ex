defmodule Tymeslot.Analytics.UtmExtractor do
  @moduledoc """
  Extracts UTM and known attribution parameters from query params.

  Standard UTM fields land in their own typed keys (so they get dedicated
  columns and indexes). A small **allowlist** of campaign-level attribution
  params is preserved in a `tracking_params` map.

  The allowlist is deliberate: `tracking_params` is persisted both to
  `analytics_events` and, on booking, onto the invitee's `meetings` row next
  to their name and email, indefinitely. Capturing *arbitrary* query params
  there would silently persist visitor PII (e.g. `?email=`, `?phone=`,
  session tokens) onto a personal-data record. Only recognised attribution
  tags are kept; everything else is dropped.

  Ad click identifiers (`gclid`, `fbclid`, `msclkid` and the like) are
  personal data even though they look opaque: the ad network can resolve
  each one to the person who clicked, so storing one beside the invitee's
  name and email links them to their ad-platform profile. They are never
  stored. Their presence is recorded only as `"ad_network"`, the name of
  the network that appended them (`"google"`, `"meta"`, ...), which is the
  same for every visitor from that network.
  """

  @utm_keys ~w(utm_source utm_medium utm_campaign utm_content utm_term)

  # Allowlist of non-UTM attribution params preserved in `tracking_params`.
  # Limited to tags that describe a campaign or a source rather than a
  # person: `gclsrc` names the Google product a click came from, `mc_cid`
  # identifies a Mailchimp campaign, and `ref` is the generic referral tag.
  # Never widen this to "any param", and never add a per-click or
  # per-recipient identifier (Mailchimp's `mc_eid` is one).
  @tracking_keys ~w(gclsrc mc_cid ref)

  # Per-click identifiers ad networks append to landing URLs, mapped to the
  # network that issued them. The identifier itself is dropped; only the
  # network survives, under `"ad_network"`. Instagram's `igshid` is not
  # listed: it identifies the person who shared a link, not an ad click, so
  # it says nothing about a campaign and is dropped like any unknown param.
  @click_id_networks %{
    "gclid" => "google",
    "gbraid" => "google",
    "wbraid" => "google",
    "dclid" => "google",
    "fbclid" => "meta",
    "msclkid" => "microsoft",
    "ttclid" => "tiktok",
    "twclid" => "x",
    "li_fat_id" => "linkedin",
    "yclid" => "yandex",
    "rdt_cid" => "reddit",
    "epik" => "pinterest"
  }

  @ad_networks @click_id_networks |> Map.values() |> Enum.uniq()

  # The scheduling flow re-appends `tracking_params` to the query string
  # when it navigates between routes (`TymeslotWeb.Themes.Shared.LiveHelpers.tracking_path/2`),
  # so `ad_network` has to survive a round trip through the URL. Only the
  # network names above are accepted, so a hand-written value can never
  # smuggle anything else in.
  @ad_network_key "ad_network"

  @max_value_length 255
  @max_tracking_keys 16

  @type extracted :: %{
          utm_source: String.t() | nil,
          utm_medium: String.t() | nil,
          utm_campaign: String.t() | nil,
          utm_content: String.t() | nil,
          utm_term: String.t() | nil,
          tracking_params: %{String.t() => String.t()}
        }

  @spec extract(map() | nil) :: extracted()
  def extract(nil), do: empty()
  def extract(params) when params == %{}, do: empty()

  def extract(params) when is_map(params) do
    base = empty()

    Enum.reduce(params, base, fn
      {k, v}, acc when is_binary(k) and is_binary(v) ->
        place(acc, k, truncate(v))

      _other, acc ->
        acc
    end)
  end

  @spec referrer_host(String.t() | nil) :: String.t() | nil
  def referrer_host(nil), do: nil
  def referrer_host(""), do: nil

  def referrer_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host |> String.downcase() |> String.slice(0, 255)

      _other ->
        nil
    end
  end

  defp empty do
    %{
      utm_source: nil,
      utm_medium: nil,
      utm_campaign: nil,
      utm_content: nil,
      utm_term: nil,
      tracking_params: %{}
    }
  end

  defp place(acc, key, value) when key in @utm_keys do
    Map.put(acc, String.to_existing_atom(key), value)
  end

  defp place(acc, key, _value) when is_map_key(@click_id_networks, key) do
    put_tracking(acc, @ad_network_key, Map.fetch!(@click_id_networks, key))
  end

  defp place(acc, @ad_network_key, value) when value in @ad_networks do
    put_tracking(acc, @ad_network_key, value)
  end

  defp place(acc, key, value) when key in @tracking_keys do
    put_tracking(acc, key, value)
  end

  # Anything outside the UTM set and the attribution allowlist is dropped:
  # routing params (username, slug, …) and any unrecognised param that could
  # carry visitor PII never reach the persisted tracking map.
  defp place(acc, _key, _value), do: acc

  defp put_tracking(acc, key, value) do
    Map.update!(acc, :tracking_params, fn params ->
      if map_size(params) >= @max_tracking_keys do
        params
      else
        Map.put(params, key, value)
      end
    end)
  end

  defp truncate(value) when byte_size(value) <= @max_value_length, do: value
  defp truncate(value), do: String.slice(value, 0, @max_value_length)
end
