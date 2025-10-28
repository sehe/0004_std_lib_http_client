#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/program_options.hpp>
#include <cassert>
#include <fstream>
#include <iostream>
#include <spanstream>

namespace po    = boost::program_options;
namespace asio  = boost::asio;
namespace beast = boost::beast;
namespace http  = beast::http;
using asio::ip::tcp;
using local = asio::local::stream_protocol;

struct Config {
    std::string host;
    uint16_t    port;
    std::string transport_type = "tcp";
    uint64_t    num_requests   = 1000;
    std::string data_file      = "benchmark_data.bin";
    std::string output_file    = "latencies_boost.bin";
    bool        verify         = true;
    bool        unsafe_res     = false;
};

struct BenchmarkData {
    std::string               raw_file_content;
    uint64_t                  num_requests;
    std::span<uint64_t const> sizes;
    std::string_view          data_block;
};

bool parse_args(int argc, char* argv[], Config& config) {
    try {
        po::options_description desc("Boost.Beast Benchmark Client Options");
        // clang-format off
        desc.add_options()
            ("help,h", "Show this help message")
            ("host", po::value<std::string>(&config.host)->required(), "The server host (e.g., 127.0.0.1) or path to Unix socket.")
            ("port", po::value<uint16_t>(&config.port)->required(), "The server port (ignored for Unix sockets).")
            ("transport", po::value<std::string>(&config.transport_type)->default_value("tcp"), "Transport to use: 'tcp' or 'unix'")
            ("num-requests", po::value<uint64_t>(&config.num_requests)->default_value(1000), "Number of requests to make.")
            ("data-file", po::value<std::string>(&config.data_file)->default_value("benchmark_data.bin"), "Path to the pre-generated data file.")
            ("output-file", po::value<std::string>(&config.output_file)->default_value("latencies_boost.bin"), "File to save raw latency data to.")
            ("no-verify", po::bool_switch()->default_value(false), "Disable checksum validation.")
            ("unsafe", po::bool_switch()->default_value(false), "Use non-owning span_body for requests (zero-copy send).")
        ;
        // clang-format on

        po::variables_map vm;
        po::store(po::parse_command_line(argc, argv, desc), vm);

        if (vm.count("help")) {
            std::cout << desc << std::endl;
        } else {
            po::notify(vm);
            config.verify     = !vm["no-verify"].as<bool>();
            config.unsafe_res = vm["unsafe"].as<bool>();
            return true;
        }
    } catch (po::error const& e) {
        std::cerr << "Error parsing arguments: " << e.what() << std::endl;
    }
    return false;
}

bool read_benchmark_data(std::string const& filename, BenchmarkData& data) {
    static_assert(std::is_trivial_v<decltype(data.num_requests)>);
    static_assert(std::is_trivial_v<decltype(data.sizes)::value_type>);
    static_assert(std::is_trivial_v<decltype(data.data_block)::value_type>);

    std::ifstream ifs(filename, std::ios::binary);
    data.raw_file_content.assign(std::istreambuf_iterator<char>(ifs), {});

    std::string_view remain(data.raw_file_content);

    if (auto expect = sizeof(data.num_requests); remain.size() < expect)
        throw std::length_error("data file too short");
    else {
        memcpy(&data.num_requests, remain.data(), expect);
        remain.remove_prefix(expect);
    }

    if (auto expect = data.num_requests * sizeof(data.sizes.front()); remain.size() < expect)
        throw std::length_error("data sizes segment too short");
    else {
        data.sizes = {reinterpret_cast<uint64_t const*>(remain.data()), data.num_requests};
        remain.remove_prefix(expect);
    }

    data.data_block = remain;
    return ifs.good();
}

uint64_t xor_checksum(uint64_t acc, auto b, auto e) {
    for (auto it = b; it != e; ++it)
        acc = std::rotr(acc, 7) ^ static_cast<unsigned char>(*it);
    return acc;
}

uint64_t xor_checksum(auto b, auto e)        { return xor_checksum(0ul, b, e);                     } 
uint64_t xor_checksum(std::string_view data) { return xor_checksum(0ul, data.begin(), data.end()); } 

uint64_t get_nanoseconds() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::high_resolution_clock::now().time_since_epoch())
        .count();
}

template <class Stream>
void run_benchmark(Stream& stream, Config const& config, BenchmarkData const& data,
                   std::vector<int64_t>& latencies) {
    std::string        payload_buffer;
    beast::error_code  ec;
    beast::flat_buffer buffer;

    for (uint64_t i = 0; i < config.num_requests; ++i) {
        size_t           req_size   = data.sizes[i % data.sizes.size()];
        std::string_view body_slice = data.data_block.substr(0, req_size);

        if (config.verify) {
            http::request<http::string_body> req{http::verb::post, "/", 11};
            req.set(http::field::host, config.host);
            req.keep_alive(true);
            payload_buffer.assign(body_slice);
            std::format_to(back_inserter(payload_buffer), "{:016X}", xor_checksum(body_slice));
            req.body() = std::move(payload_buffer);
            req.prepare_payload();
            http::write(stream, req, ec);
        } else if (config.unsafe_res) {
            http::request<http::span_body<char const>> req{http::verb::post, "/", 11, body_slice};
            req.set(http::field::host, config.host);
            req.keep_alive(true);
            req.prepare_payload();
            http::write(stream, req, ec);
        } else {
            http::request<http::string_body> req{http::verb::post, "/", 11};
            req.set(http::field::host, config.host);
            req.keep_alive(true);
            req.body().assign(body_slice);
            req.prepare_payload();
            http::write(stream, req, ec);
        }

        if (ec) {
            std::cerr << "Write failed: " << ec.message() << std::endl;
            break;
        }

        http::response_parser<http::buffer_body> parser;

        auto& response = parser.get(); // convenience shorthands
        auto& body_val = response.body();

        beast::flat_buffer buf;
        read_header(stream, buf, parser, ec);

        if (ec && ec != http::error::need_buffer) // expected
            throw boost::system::system_error(ec);

        assert(p.is_header_done());

        auto content_length = parser.content_length().value();

        uint64_t checksum = 0;
        size_t   body_len = 0;
        size_t   meta_len = config.verify ? 16 + 19 : 19;
        // std::vector<char> block(content_length + meta_len);
        std::vector<char> block(std::min(2048ul, content_length + meta_len));
        std::string_view  last_block;

        while (!parser.is_done()) {
            body_val.data = block.data();
            body_val.size = block.size();
            http::read(stream, buf, parser, ec);

            if (ec && ec != http::error::need_buffer) // expected
                break;

            size_t n  = block.size() - body_val.size;
            body_len += n;

            if (body_len >= content_length) {
                last_block = {block.data(), n};
                if (config.verify && n > meta_len)
                    checksum = xor_checksum(checksum, block.data(), block.data() + n - meta_len);
            } else if (config.verify)
                checksum = xor_checksum(checksum, block.data(), block.data() + n);
        }

        auto client_receive_time = get_nanoseconds();

        if (ec) {
            std::cerr << "Read failed: " << ec.message() << std::endl;
            break;
        }

        if (config.verify) {
            if (last_block.length() < meta_len)
                std::cerr << "Warning: Last block too short for metadata " << i << std::endl;
            else {
                auto res_checksum_hex = last_block.substr(last_block.length() - meta_len, 16);

                if (uint64_t expected = 0; std::ispanstream(res_checksum_hex) >> std::hex >> expected) {
                    if (checksum != expected) {
                        std::cerr << "Warning: Response checksum mismatch on request " << i << std::endl;
                        std::cerr << "Exptected: " << quoted(res_checksum_hex) << std::endl;
                    }
                } else
                    std::cerr << "Warning: Response checksum cannot be parsed" << i << std::endl;
            }
        }

        if (last_block.length() < 19)
            std::cerr << "Warning: Last block too small for timestamp metadata " << i << std::endl;
        {
            auto     server_timestamp_str = last_block.substr(last_block.length() - 19);
            uint64_t server_timestamp     = std::stoull(std::string(server_timestamp_str));
            latencies[i]                  = client_receive_time - server_timestamp;
        }

        buffer.consume(buffer.size());
    }
}

int main(int argc, char* argv[]) {
    Config config;
    if (!parse_args(argc, argv, config)) {
        return 1;
    }

    BenchmarkData data;
    if (!read_benchmark_data(config.data_file, data)) {
        return 2;
    }

    asio::io_context  ioc;
    beast::error_code ec;

    std::vector<int64_t> latencies(config.num_requests);

    if (config.transport_type == "tcp") {
        tcp::resolver resolver(ioc);
        tcp::socket   socket(ioc);
        auto results = resolver.resolve(config.host, std::to_string(config.port));
        asio::connect(socket, std::move(results));
        run_benchmark(socket, config, data, latencies);
        socket.shutdown(tcp::socket::shutdown_both, ec);
    } else if (config.transport_type == "unix") {
        local::socket socket(ioc);
        socket.connect(config.host); // For Unix, host is the path
        run_benchmark(socket, config, data, latencies);
        socket.shutdown(local::socket::shutdown_both, ec);
    }

    std::ofstream out_file(config.output_file, std::ios::binary);
    if (out_file) {
        out_file.write(reinterpret_cast<char const*>(latencies.data()), latencies.size() * sizeof(int64_t));
    }

    std::cout << "boost_client: completed " << config.num_requests << " requests." << std::endl;
}
