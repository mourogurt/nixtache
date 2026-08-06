# 07 — Cross-arch

> Этап 9 из `0001` §11. Детализация §12.D / §7.3 `0001`.
> **Статус:** 📝 черновик.

## Принцип

Arch **не хардкодится** нигде — выводится из декларации: `nixpkgs.hostPlatform`/
`pkgs.system` конфига (для `nixosConfigurations`) и явный `system` в `devShells`.
Рабочий набор сейчас: `x86_64-linux`, `aarch64-linux` (расширяется по мере появления
хостов). Никаких флагов `--system` вручную.

## Механизм сборки: binfmt-эмуляция на runner-host

Action'ы `rebuild-configurations` / `rebuild-devshells` **arch-агностичны** — они
просто `nix build` заявленный toplevel/devShell (чьё поле `system` = arch цели). На
x86_64-runner собрать `aarch64`-вывод позволяет **binfmt-эмуляция** на runner-host:

```nix
# consumer, конфиг runner-host'а (машины с nixtache):
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];   # + любые нужные
```

`boot.binfmt.emulatedSystems` регистрирует QEMU-user через binfmt_misc → `nix-daemon`
раннера может исполнять aarch64-билдеры в sandbox. Медленнее native, но для CI-сборки
приемлемо; ноль доп. инфраструктуры (N6 решено = binfmt).

## Поведение CI

- `rebuild-configurations`: для каждого `nixosConfigurations.<name>` строит
  `.config.system.build.toplevel` — system берётся из `nixpkgs.hostPlatform` конфига.
  На runner-host с эмуляцией — собирается cross-arch; **без эмуляции под нужную arch →
  `nix build` fail → CI красный (N8)**. Тихий skip опасен — явный fail.
- `rebuild-devshells`: то же для `devShells.<system>.<name>` (там `system` явный в
  ключе); cross-arch devShell → needs эмуляция, иначе fail.

> Config/devShell сборки «под что собирать» заданы **явно** в декларации; fail CI при
> нереализуемой arch — это корректное поведение (не сюрприз).

## Deploy cross-arch (`02-action`)

> **S4 + V2:** `--build-host`/`buildHost`/`remoteBuild`/deploy-rs — всё убрано.
> `nix build` (его используют и `_liveApply` для toplevel, и `_abImage` для
> sysupdate-package) флага `--build-host` не имеет, а deploy-rs выкинут целиком.
> Cross-arch сборка — **единственный механизм**: binfmt-эмуляция на runner-host.

**Механизм сборки cross-arch цели (единственный):**

`boot.binfmt.emulatedSystems` на runner-host регистрирует QEMU-user → `nix build`
собирает aarch64-деривации (toplevel / sysupdate-package) в sandbox на раннере.
Медленнее native, но ноль доп. инфраструктуры и единый путь. Closure затем
копируется на цель (`nix copy --to`) и активируется root-юнитом (`_liveApply`) /
stage'ится для sysupdate (`_abImage`).

```nix
# пример cross-arch цели в карте (без buildHost/remoteBuild — поля убраны):
services.nixtache.runner.deploy.targets.rpi4 = {
  host          = "10.13.37.4";
  sshUser       = "nixos-deploy";
  sshPrivateKey = config.sops.secrets.deploy-key-rpi4.path;
  system        = "aarch64-linux";   # обычно derive из hostPlatform, но можно явно
};
```

> Native-сборка на самой цели (без эмуляции) в V2 не поддерживается — потребовала
> бы `nix build` на цели и `nix copy` обратно, что ломает модель «раннер собирает,
> цель только активирует». Если появится тяжёлая cross-arch цель, где эмуляция
> неприемлема — вынести в отдельную подзадачу (напр. dedicated builder-машина в
> `nix.settings.builders`), не в карту.

## Tests (`tests/runner.nix`)

- цель `system = "aarch64-linux"`: `NIXTACHE_DEPLOY_TARGETS` JSON несёт `system`.
- `buildHost` поле **отсутствует** в JSON (assert: сериализация без него).
- (host-side) `boot.binfmt.emulatedSystems` — не responsibility nixtache
  (consumer), но задокументировано в `04`/README consumer'а.

## Артефакты

- nixtache: `02-action` — **без** `--build-host`/`remoteBuild` (убрано);
  `rebuild-*` actions уже arch-агностичны (без правок).
- consumer: `boot.binfmt.emulatedSystems` на runner-host.

## Зависимости

- ← `01` (поле `system` в карте; `buildHost` убран).
- Независимый этап; можно реализовать когда появится не-`x86_64` цель.
