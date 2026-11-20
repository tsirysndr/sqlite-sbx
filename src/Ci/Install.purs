module Ci.Install (install, verifyDriver) where

import Prelude
import Ci.Common as C
import Ci.Native as N
import Data.Array as A
import Data.Maybe (fromMaybe)
import Data.String as S
import Effect.Aff (Aff)
import Effect.Class (liftEffect)

-- Overlay snapshots require a real backing filesystem, including after the
-- engine restarts to attach a ZFS volume. Never silently fall back to VFS.
verifyDriver :: String -> Aff Unit
verifyDriver runtime = do
  status <- C.run runtime [ "docker", "status", "--json" ] >>= C.fromEither <<< C.jsonSuffix <<< _.stdout
  socket <- C.fromEither (C.stringField "socket" status)
  info <- C.run "docker" [ "--host", "unix://" <> socket, "info", "--format", "{{.Driver}}" ]
  C.demand "CI requires overlayfs or overlay2; VFS is not allowed" (A.elem (S.trim info.stdout) [ "overlayfs", "overlay2" ])
  filesystem <- C.run runtime [ "exec", "bsdkrun-docker", "stat", "-f", "-c", "%T", "/var/lib/docker" ]
  C.demand "Docker's image store must remain ext4 after restart" (S.trim filesystem.stdout == "ext2/ext3")

install :: String -> Aff Unit
install version = do
  C.demand "Expected a bsdkrun release such as v0.12.1" (C.matches "^v[0-9]+\\.[0-9]+\\.[0-9]+$" version)
  host <- liftEffect N.platform
  C.demand "The installer requires Ubuntu x86_64 with KVM" (host.os == "linux" && host.arch == "x64")
  liftEffect (N.exists "/dev/kvm") >>= C.demand "/dev/kvm is required; live tests are never skipped"
  void $ C.run "sudo" [ "-n", "apt-get", "update" ]
  void $ C.run "sudo" [ "-n", "apt-get", "install", "-y", "--no-install-recommends", "ca-certificates", "curl", "tar", "gzip", "xz-utils", "libgmp10", "libtinfo6" ]
  void $ C.run "sudo" [ "-n", "chmod", "a+rw", "/dev/kvm" ]
  liftEffect (N.readableWritable "/dev/kvm") >>= C.demand "KVM must be readable and writable"
  void $ C.run "docker" [ "--version" ]
  root <- liftEffect (N.resolve ".fluentci/tools/bsdkrun")
  let bin = root <> "/bin"
  liftEffect (N.mkdir bin)
  let asset = "bsdkrun-x86_64-unknown-linux-gnu.tar.gz"
  let base = "https://github.com/tsirysndr/bsdkrun/releases/download/" <> version <> "/" <> asset
  download base (root <> "/" <> asset)
  download (base <> ".sha256") (root <> "/" <> asset <> ".sha256")
  checksum <- liftEffect (N.readText (root <> "/" <> asset <> ".sha256"))
  actual <- liftEffect (N.sha256 (root <> "/" <> asset))
  let expected = fromMaybe "" (A.head (S.split (S.Pattern " ") (S.trim checksum)))
  C.demand "bsdkrun release checksum mismatch" (C.matches "^[a-fA-F0-9]{64}$" expected && S.toLower expected == actual)
  void $ C.run "tar" [ "-xzf", root <> "/" <> asset, "-C", bin ]
  -- Linux CLI bundles supervisor + libkrun/libkrunfw beside the executable.
  download "https://github.com/containers/gvisor-tap-vsock/releases/latest/download/gvproxy-linux-amd64" (bin <> "/gvproxy")
  liftEffect (N.chmod (bin <> "/gvproxy") 493)
  C.prepareRuntime
  runtime <- C.bsdkrun
  void $ C.run runtime [ "--version" ]
  void $ C.run runtime [ "probe" ]

download :: String -> String -> Aff Unit
download url destination = void $ C.run "curl" [ "--fail", "--show-error", "--silent", "--location", "--retry", "3", url, "-o", destination ]
