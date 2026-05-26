# Multi-stage: build with the full toolchain, run on a slim image.
FROM swift:6.0-jammy AS build
WORKDIR /build
# Resolve deps first for layer caching. Both packages' manifests are copied.
COPY ./WickServer/Package.* ./WickServer/
COPY ./TradingFloor ./TradingFloor
WORKDIR /build/WickServer
RUN swift package resolve
COPY ./WickServer/Sources ./Sources
RUN swift build -c release --product WickServer

FROM swift:6.0-jammy-slim
WORKDIR /app
COPY --from=build /build/WickServer/.build/release/WickServer .
# ANTHROPIC_API_KEY / FINNHUB_API_KEY / PORT / REPORT_STORE_DIR via env.
EXPOSE 8080
ENTRYPOINT ["./WickServer"]
