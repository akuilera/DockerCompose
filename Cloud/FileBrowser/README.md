FileBrowser is going to be used to manipulate files.

You have to specify the variables by copying or changing the name of the `env.example` file to `.env` and modify it.

You have to change the permissions in `${DISK_UUID_PATH}/Containers/FileBrowser/config`, by executing

```
sudo chown -R 1000:1000 /${DISK_UUID_PATH}/Containers/FileBrowser
sudo chmod -R 755 /${DISK_UUID_PATH}/Containers/FileBrowser
```
**You have to change ${DISK_UUID_PATH} with the actual path**

To log in you have to run `sudo docker logs filebrowser` and look for the randomly generated user and password.
