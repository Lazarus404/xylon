defmodule Xylon.MixProject do
  use Mix.Project

  def project do
    [
      app: :xylon,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Modular WebRTC media server (sessions and backends).",
      source_url: "https://github.com/Lazarus404/xylon",
      docs: [
        extras: ["README.md"],
        main: "readme"
      ],
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Xylon.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:xgw, "~> 0.1.0"},
      {:xsdp, "~> 0.1.0"},
      {:xmedialib, "~> 0.3.0"},
      {:xsip, "~> 0.1.0"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:jose, "~> 1.11"},
      {:grpc, "~> 0.11"},
      {:protobuf, "~> 0.14"},
      {:libcluster, "~> 3.3"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/Lazarus404/xylon"}
    ]
  end
end
