# Contributing Guidelines

Thank you for your interest in contributing to **checksums**!  
This project welcomes improvements, but please follow these rules so everything stays consistent.

---

## 📜 License & Rights

- By contributing, you agree that your contributions are licensed under the same terms as the project (see LICENSE.md).  
- Intellectual property rights remain with the project owner (Alexandru Barbu).  
- Contributions are welcome, but redistribution or commercial use of the project is not permitted.

---

## 🛠️ Development Workflow

1. **Fork & Clone**  
   Fork the repository and clone it locally.

2. **Create a Branch**  
   Use a descriptive branch name:  

       git checkout -b feat/add-sha512

3. **Follow Commit Conventions**  
   Use [Conventional Commits](https://www.conventionalcommits.org/):  
   - `feat:` for new features  
   - `fix:` for bug fixes  
   - `docs:` for documentation changes  
   - `chore:` for maintenance  
   - `test:` for test-related changes  

   Example:  

       feat: add SHA512 checksum support

4. **Run Checks Before Pushing**  

       make check

   This runs lint, tests, and changelog preview.

5. **Update Changelog**  

       make changelog-draft

   This ensures your changes appear under the `[Unreleased]` section.

6. **Push & Open a PR**  
   Push your branch and open a Pull Request.  
   CI will:
   - Run tests and lint  
   - Post a changelog preview as a PR comment  
   - Auto-update `CHANGELOG.md` with draft entries  

---

## ✅ PR Review Checklist

- [ ] Code passes `make check`  
- [ ] Commit messages follow Conventional Commits  
- [ ] Changelog updated under `[Unreleased]`  
- [ ] Tests added/updated if needed  

---

## 🙌 Code of Conduct

Please be respectful and constructive. Contributions are welcome from anyone who follows these guidelines.
