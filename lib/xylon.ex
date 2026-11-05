defmodule Xylon do
  @moduledoc """
  Entry point for a modular real-time media server.

  ## What problem this solves

  Browsers and softphones can send live audio, video, and data over the internet,
  but a server must negotiate how to connect (addresses, codecs, encryption) and
  decide what to do with incoming media (echo it back, mix a conference, record,
  and so on). Xylon is that server layer: it runs **sessions** (calls or rooms),
  accepts **signaling** (HTTP JSEP or SIP) to set each session up, and routes
  decrypted media through a pluggable **backend** you attach at runtime.

  Plaintext RTP/RTCP and datachannel payloads come from
  [XGW](https://github.com/Lazarus404/xgw) after DTLS-SRTP termination.
  SDP offer/answer negotiation uses [XSDP](https://github.com/Lazarus404/xsdp).
  ICE host candidates and gather options are configured via `Xylon.Ice`.

  ## RFCs and related specs

  - [RFC 3264](https://www.rfc-editor.org/rfc/rfc3264) -- SDP offer/answer (via XSDP)
  - [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445) -- ICE (via XGW and `Xylon.Ice`)
  - [RFC 5764](https://www.rfc-editor.org/rfc/rfc5764) -- DTLS-SRTP (via XGW)
  - [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261) -- SIP (optional lab signaling)
  - [RFC 7118](https://www.rfc-editor.org/rfc/rfc7118) -- SIP over WebSocket
  - W3C/IETF **JSEP** -- browser offer/answer signaling over HTTP in lab tasks
  """

  @doc """
  Registers a media backend module in the catalogue.

  The module must export `id/0` (returns its catalogue atom) and implement
  `Xylon.Backend` (at minimum `init/2` and the required callbacks).

  Returns `:ok` on success or `{:error, :invalid_backend}` when `id/0` or `init/2`
  is missing.
  """
  @spec attach(module()) :: :ok | {:error, :invalid_backend}
  def attach(module) when is_atom(module) do
    _ = Code.ensure_loaded(module)

    with true <- function_exported?(module, :id, 0),
         id when is_atom(id) <- module.id(),
         true <- function_exported?(module, :init, 2) do
      Xylon.Catalogue.put(id, module)
    else
      _ -> {:error, :invalid_backend}
    end
  end

  @doc """
  Returns `true` when catalogue id `id` was registered via `attach/1`.
  """
  @spec attached?(atom()) :: boolean()
  def attached?(id) when is_atom(id) do
    match?({:ok, _}, Xylon.Catalogue.fetch(id))
  end

  @doc """
  Default backend catalogue id when signaling does not name one explicitly.

  Reads `Application.get_env(:xylon, :default_backend, :echo)`. The Application
  supervisor verifies this id is attached at boot.
  """
  @spec default_backend() :: atom()
  def default_backend do
    Application.get_env(:xylon, :default_backend, :echo)
  end
end
