# router-check

Проверка VPN (sing-box) на роутере. Ничего не меняет, только читает.

Зайти на роутер по ssh и выполнить одну строку:

```
curl -fsSL https://raw.githubusercontent.com/pometov/router-check/main/check.sh | sh
```

Зелёное - в порядке, красное - проблема (рядом написано, что делать). Если есть красное, скопируй весь вывод и пришли.
