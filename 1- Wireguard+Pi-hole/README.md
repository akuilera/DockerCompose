You have to generate a hash bcrypt of the password that you want, to put it in .env.
You do that by running `docker run --rm ghcr.io/wg-easy/wg-easy wgpw YOUR_SUPER_STRONG_PASSWORD`

You also have to change every "$" to "$$" in the password 🤷‍♂️

If Pi-hole has problems with the credentials, change the password with the given instructions inside the container: `pihole setpassword` (our in the host `sudo docker exec -it pihole pihole setpassword`)