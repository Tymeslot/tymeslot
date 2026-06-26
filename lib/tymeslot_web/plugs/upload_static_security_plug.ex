defmodule TymeslotWeb.Plugs.UploadStaticSecurity do
  @moduledoc """
  Security wrapper that guards the `/uploads` static-file mount.

  Three concerns:

  * **Extension allowlist.** Upload flows produce images (`.jpg`, `.jpeg`,
    `.png`, `.gif`, `.webp`), videos (`.mp4`, `.webm`, `.mov`), and
    host-uploaded meeting attachments (`.pdf`, `.doc`, `.docx`, `.xls`,
    `.xlsx`, `.ppt`, `.pptx`, `.txt`, `.csv`). Anything else reaching the
    upload directory is either an attacker artefact that bypassed an upload
    validator or a historical file that should no longer be served. Requests
    for unlisted extensions return `404` before `Plug.Static` touches the
    filesystem.

  * **MIME sniffing.** `X-Content-Type-Options: nosniff` is added to every
    allowed `/uploads` response so browsers cannot override the
    `Content-Type` that `Plug.Static` sets.

  * **Forced download for attachments.** Requests under
    `/uploads/attachments/` additionally receive
    `Content-Disposition: attachment`, which prevents browsers from rendering
    document types inline and neutralises stored-XSS via an uploaded file.

  Must be plugged **before** the `/uploads` `Plug.Static` in the endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  alias TymeslotWeb.Helpers.UploadConstraints

  @uploads_prefix "uploads"
  @attachments_prefix "attachments"

  @allowed_extensions MapSet.new(
                        UploadConstraints.allowed_extensions(:avatar) ++
                          UploadConstraints.allowed_extensions(:image) ++
                          UploadConstraints.allowed_extensions(:video) ++
                          UploadConstraints.allowed_extensions(:attachment)
                      )

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{halted: true} = conn, _opts), do: conn

  def call(%{path_info: [@uploads_prefix | rest]} = conn, _opts) when rest != [] do
    if allowed_extension?(rest) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> maybe_force_download(rest)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  # Meeting attachments can be document types whose browsers might render
  # inline (and execute embedded content). Forcing a download — alongside
  # `nosniff` — neutralises stored-XSS via an uploaded file.
  defp maybe_force_download(conn, [@attachments_prefix | _rest]) do
    put_resp_header(conn, "content-disposition", "attachment")
  end

  defp maybe_force_download(conn, _segments), do: conn

  defp allowed_extension?(segments) do
    ext =
      segments
      |> List.last()
      |> Path.extname()
      |> String.downcase()

    MapSet.member?(@allowed_extensions, ext)
  end
end
