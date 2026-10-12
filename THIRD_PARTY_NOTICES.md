# Third-party notices

Quiet uses the pinned packages below. Their licenses apply independently of Quiet’s MIT code license. These are the complete resolved package graph, including build-time and transitive packages; inclusion here does not mean every package is linked into every executable.

| Package | Version / pinned source | Retained notices |
| --- | --- | --- |
| eventsource | [1.5.1](https://github.com/mattt/EventSource/tree/86b5096ac59ab46e66bd1f6377c604bc1dab0bc2) | [eventsource-LICENSE.md](LICENSES/eventsource-LICENSE.md) |
| mlx-swift | [0.32.3](https://github.com/ml-explore/mlx-swift/tree/19601207e9a0de51e03ee6ec0c3c5f3784275075) | [mlx-swift-LICENSE](LICENSES/mlx-swift-LICENSE) |
| mlx-swift-lm | [3.32.3](https://github.com/ml-explore/mlx-swift-lm/tree/3b339ad6e3b3f44c8121ecff5131c7fd55e075e6) | [mlx-swift-lm-LICENSE](LICENSES/mlx-swift-lm-LICENSE) |
| swift-asn1 | [1.7.3](https://github.com/apple/swift-asn1/tree/3b6410f7dee09eb33cdd26260c5fd47fda19b0e2) | [swift-asn1-LICENSE.txt](LICENSES/swift-asn1-LICENSE.txt), [swift-asn1-NOTICE.txt](LICENSES/swift-asn1-NOTICE.txt) |
| swift-collections | [1.7.2](https://github.com/apple/swift-collections/tree/3b69cedbaa49957e97c092ae400bb57602ef941f) | [swift-collections-LICENSE.txt](LICENSES/swift-collections-LICENSE.txt) |
| swift-crypto | [4.5.2](https://github.com/apple/swift-crypto/tree/da9d28d69ebe3894b18376c8f2395c2f37b8448f) | [swift-crypto-LICENSE.txt](LICENSES/swift-crypto-LICENSE.txt), [swift-crypto-NOTICE.txt](LICENSES/swift-crypto-NOTICE.txt) |
| swift-huggingface | [0.13.0](https://github.com/huggingface/swift-huggingface/tree/f0a0cb43cb1b402d2bbf6fb10d8981328c449c48) | [swift-huggingface-LICENSE](LICENSES/swift-huggingface-LICENSE) |
| swift-jinja | [2.5.1](https://github.com/huggingface/swift-jinja/tree/4588064a20f3fc093c95f2f7d3359999bf30cae5) | [swift-jinja-LICENSE](LICENSES/swift-jinja-LICENSE) |
| swift-numerics | [1.1.1](https://github.com/apple/swift-numerics/tree/0c0290ff6b24942dadb83a929ffaaa1481df04a2) | [swift-numerics-LICENSE.txt](LICENSES/swift-numerics-LICENSE.txt) |
| swift-syntax | [603.0.2](https://github.com/swiftlang/swift-syntax/tree/79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1) | [swift-syntax-LICENSE.txt](LICENSES/swift-syntax-LICENSE.txt) |
| swift-transformers | [1.3.4](https://github.com/huggingface/swift-transformers/tree/c21fdcde390313a6d98d8e33a346f2c3486c3ab0) | [swift-transformers-LICENSE](LICENSES/swift-transformers-LICENSE) |
| yyjson | [0.12.0](https://github.com/ibireme/yyjson/tree/8b4a38dc994a110abaec8a400615567bd996105f) | [yyjson-LICENSE](LICENSES/yyjson-LICENSE) |

License texts are retained verbatim under `LICENSES/`. Preserve applicable notices when redistributing source or binaries. A dependency update requires repeating this review, including licenses of embedded C/C++ libraries and submodules.

## Models and system software

Model weights are not included and are not relicensed by Quiet. Review the license and model card of any model before downloading, using or redistributing it. Model downloads may contain their own notices; retain them. MLX is a runtime license, not a blanket license for compatible models. Apple frameworks and any separately installed Ollama executable remain subject to their respective terms.

## Original artwork

Original Glyph artwork is CC BY 4.0 with attribution to Mëngøh Labs; see [asset terms](LICENSE-ASSETS.md). Trademark rights remain separate.

## Embedded library notices

The pinned checkouts also contain the following embedded license/notice files, retained verbatim with their relative paths. These include MLX, its C interface, Metal C++ headers, fmt, nlohmann JSON and XGrammar.

- `mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt`: [retained text](LICENSES/embedded/mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt)
- `mlx-swift/Source/Cmlx/fmt/LICENSE`: [retained text](LICENSES/embedded/mlx-swift/Source/Cmlx/fmt/LICENSE)
- `mlx-swift/Source/Cmlx/mlx-c/LICENSE`: [retained text](LICENSES/embedded/mlx-swift/Source/Cmlx/mlx-c/LICENSE)
- `mlx-swift/Source/Cmlx/json/LICENSE.MIT`: [retained text](LICENSES/embedded/mlx-swift/Source/Cmlx/json/LICENSE.MIT)
- `mlx-swift/Source/Cmlx/mlx/LICENSE`: [retained text](LICENSES/embedded/mlx-swift/Source/Cmlx/mlx/LICENSE)
- `mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/LICENSE`: [retained text](LICENSES/embedded/mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/LICENSE)
- `mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/NOTICE`: [retained text](LICENSES/embedded/mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/NOTICE)

The Swift Crypto vendored BoringSSL revision is `0226f30467f540a3f62ef48d453f93927da199b6`, recorded in its pinned Package.swift. Its [full license](LICENSES/embedded/swift-crypto/BoringSSL-LICENSE) and [copyright/license blocks from vendored BoringSSL and XKCP sources](LICENSES/embedded/swift-crypto/VENDORED-SOURCE-NOTICES.txt) are retained. The Mac build may use platform CryptoKit for some operations; these notices cover the resolved source graph without asserting that every vendored routine is linked.

The optional Python verification environment uses pyte and wcwidth; they are test tools, not app/CLI runtime dependencies. Their package distributions include their licenses and must retain them when redistributed.
