defmodule Tymeslot.Security.UrlValidationInternalNamesTest do
  use ExUnit.Case, async: true
  @moduletag :security

  alias Tymeslot.Security.UrlValidation

  describe "validate_http_url/2 with internal_names_local" do
    @https_only [enforce_https_for_public: true, https_error_message: "https required"]
    @internal_names @https_only ++ [internal_names_local: true]

    test "lets plain http reach a single-label host, such as a Docker service name" do
      assert :ok = UrlValidation.validate_http_url("http://nextcloud", @internal_names)
      assert :ok = UrlValidation.validate_http_url("http://nextcloud-app:8080", @internal_names)
      assert :ok = UrlValidation.validate_http_url("http://talk_server/", @internal_names)
    end

    test "lets plain http reach a host under each internal suffix" do
      for url <- [
            "http://talk.local",
            "http://talk.lan",
            "http://meet.internal",
            "http://meet.home.arpa",
            "http://cloud.office.lan:8080/nextcloud",
            "http://TALK.LAN"
          ] do
        assert {url, :ok} == {url, UrlValidation.validate_http_url(url, @internal_names)}
      end
    end

    test "still refuses plain http to a public name or address" do
      for url <- [
            "http://cloud.example.com",
            "http://lan.example.com",
            "http://talk.lan.example.com",
            "http://8.8.8.8",
            "http://[2001:4860:4860::8888]"
          ] do
        assert {url, {:error, "https required"}} ==
                 {url, UrlValidation.validate_http_url(url, @internal_names)}
      end
    end

    test "refuses a suffix on its own, which names no host" do
      assert {:error, "https required"} =
               UrlValidation.validate_http_url("http://home.arpa", @internal_names)

      assert {:error, "https required"} =
               UrlValidation.validate_http_url("http://x.arpa", @internal_names)
    end

    test "refuses internal names without the option" do
      for url <- ["http://nextcloud", "http://talk.lan", "http://meet.home.arpa"] do
        assert {url, {:error, "https required"}} ==
                 {url, UrlValidation.validate_http_url(url, @https_only)}
      end
    end

    test "never makes a name count as a private address" do
      assert :ok =
               UrlValidation.validate_http_url(
                 "https://nextcloud",
                 @internal_names ++ [block_private_ips: true]
               )
    end
  end

  describe "http_to_internal_name?/1" do
    test "is true for plain http to a name accepted only for its internal shape" do
      for url <- [
            "http://nextcloud/remote.php/dav",
            "HTTP://Nextcloud:8080",
            "http://organiser:secret@nextcloud/dav",
            "http://talk.lan",
            "http://meet.home.arpa/"
          ] do
        assert {url, true} == {url, UrlValidation.http_to_internal_name?(url)}
      end
    end

    test "is false for https, localhost, address literals and public names" do
      for url <- [
            "https://nextcloud",
            "http://localhost:8080",
            "http://172.18.0.5",
            "http://[fd00::5]",
            "http://2130706433",
            "http://cloud.example.com",
            "not a url"
          ] do
        assert {url, false} == {url, UrlValidation.http_to_internal_name?(url)}
      end
    end
  end
end
