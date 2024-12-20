# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1+2]

### Fixed
- **Bug Fix:** Fix formatting issues and ensure consistent newline usage across multiple files.

## [1.0.1+1]

### Fixed
- **Bug Fix:** Resolved an issue where the client would throw a `Null` error when attempting to access the SDK directory during documentation generation. This fix ensures smoother `dartdoc` executions without runtime type errors.
- **Dependency Update:** Updated `path_provider` to version `^2.1.5` to ensure compatibility with the latest Flutter SDKs.

### Improved
- **Performance:** Enhanced caching mechanisms to improve query execution speed and reduce unnecessary network calls.
- **Logging:** Improved logging details for better debugging and monitoring of GraphQL operations.

### Miscellaneous
- **Documentation:** Updated the usage examples in `README.md` to provide clearer guidance on configuring and utilizing the GraphQL client.
- **Code Quality:** Applied linting fixes and code formatting to adhere to Dart's best practices, ensuring maintainable and readable codebase.


## [1.0.1]

### Added
- **Initial Release**:
  - Core functionality to execute GraphQL queries and mutations.
  - Basic caching with `CachePolicy` support.
  - Error handling with `GraphQLException`.
  - Unit tests covering primary features.
  - Example usage in the `example/` directory.

---

## Contributing

Contributions are welcome! Please follow these steps:

1. **Fork the Repository**: Click the "Fork" button at the top-right corner of the repository page.
2. **Create a New Branch**: `git checkout -b feature/YourFeatureName`
3. **Commit Your Changes**: `git commit -m "Add some feature"`
4. **Push to the Branch**: `git push origin feature/YourFeatureName`
5. **Open a Pull Request**: Navigate to the repository on GitHub and click "Compare & pull request".

Please ensure your code adheres to the project's linting rules and includes appropriate tests.

## License

This project is licensed under the [MIT License](LICENSE).

## Additional Information

- **GitHub Repository**: [https://github.com/Ahmed-Reda-Dev/graphql_client_flutter](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter)
- **Issue Tracker**: [https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/issues](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/issues)
- **Documentation**: [https://pub.dev/documentation/graphql_client/latest/graphql_client/graphql_client-library.html](https://pub.dev/documentation/graphql_client/latest/graphql_client/graphql_client-library.html)
- **Examples**: Check out the [example](example/) directory for comprehensive usage examples.

---

*Maintained by Ahmed Reda. For support or questions, please open an issue on [GitHub](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/issues).*